// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation
@preconcurrency import Network
import TouchCore

/// Keep the active gesture route until the paired bridge accepts the new route.
@MainActor
public final class RacingTouchClient {
    private let onState: (String, Bool) -> Void
    private let onAuthenticated: (String, UUID?) -> Void
    private let onInitialStatus: (BridgeStatus) -> Void
    private let onPreview: (HapticPreviewCommand) -> Void
    private let onDiscardInput: (DiscardInputAcknowledgement) -> Void
    private let onPairingRevoked: () -> Void
    private let onReceipt: (WakeReceipt) -> Void
    private let onSwitchFailed: () -> Void
    public private(set) var lastWiFiFailure: WiFiFailureReport?
    private var active: Link?
    private var candidate: Link?
    private var timeout: Task<Void, Never>?
    private var forgetBrowser: NWBrowser?
    public var isConnecting: Bool { active == nil && candidate != nil }
    public var isCommitting: Bool { candidate?.claimSent == true }

    @MainActor
    private final class Link {
        var browseDenied = false
        var local: LocalChannel?
        var bluetooth: BluetoothTouchClient?
        var peripheral: UUID?
        var claim: (() -> Void)?
        var claimSent = false
        var claimID: UUID?
        var pending: UUID?
        func close() {
            claim = nil
            local?.close()
            bluetooth?.stop()
        }
    }

    public init(onState: @escaping @MainActor (String, Bool) -> Void,
                onAuthenticated: @escaping @MainActor (String, UUID?) -> Void,
                onInitialStatus: @escaping @MainActor (BridgeStatus) -> Void,
                onPreview: @escaping @MainActor (HapticPreviewCommand) -> Void,
                onDiscardInput: @escaping @MainActor (DiscardInputAcknowledgement) -> Void,
                onPairingRevoked: @escaping @MainActor () -> Void = {},
                onSwitchFailed: @escaping @MainActor () -> Void = {},
                onReceipt: @escaping @MainActor (WakeReceipt) -> Void) {
        self.onState = onState
        self.onAuthenticated = onAuthenticated
        self.onInitialStatus = onInitialStatus
        self.onPreview = onPreview
        self.onDiscardInput = onDiscardInput
        self.onPairingRevoked = onPairingRevoked
        self.onSwitchFailed = onSwitchFailed
        self.onReceipt = onReceipt
    }

    public func connect(code: String, peripheralID: UUID? = nil, deviceName: String? = nil, preferWiFi: Bool = false, requestsForget: Bool = false) {
        reset()
        lastWiFiFailure = nil
        prepare(code: code, peripheralID: peripheralID, deviceName: deviceName, wifi: preferWiFi, requestsForget: requestsForget)
    }

    public func switchRoute(pairing: SavedTouchPairing, deviceName: String, wifi: Bool, requestID: UUID? = nil) {
        guard let active, candidate == nil, (active.local != nil) != wifi else { return }
        lastWiFiFailure = nil
        prepare(code: pairing.code, peripheralID: pairing.peripheralID, deviceName: deviceName, wifi: wifi, requestsForget: false, requestID: requestID)
    }

    private func prepare(code: String, peripheralID: UUID?, deviceName: String?, wifi: Bool, requestsForget: Bool, requestID: UUID? = nil) {
        let link = Link()
        candidate = link
        let defaults = UserDefaults.standard
        let key = "touchConnectionAttempt"
        let previous = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(PhoneConnectionAttempt.self, from: $0) }
        var identity = PhoneConnectionAttempt(installation: previous?.installation ?? UUID(), sequence: (previous?.sequence ?? 0) + 1)
        defaults.set(try? JSONEncoder().encode(identity), forKey: key)
        identity.deviceName = deviceName
        if requestsForget { identity.requestsForget = true }

        let fail: @MainActor @Sendable (String) -> Void = { [weak self, weak link] message in
            guard let self, let link else { return }
            if self.active === link {
                self.active = nil
                link.close()
                // A committed claim retires the previous owner on the Mac.
                if !self.isCommitting { self.disconnect(message) }
            } else if self.candidate === link {
                if wifi {
                    self.lastWiFiFailure = WiFiFailureReport(localNetworkDenied: link.browseDenied || link.local?.localNetworkDenied == true, requestID: requestID)
                }
                let uncertain = link.claimSent
                self.clearCandidate()
                if self.active != nil && !uncertain {
                    self.onSwitchFailed()
                } else if wifi {
                    self.reset()
                    self.onState("Reconnecting over Bluetooth…", false)
                    self.prepare(code: code, peripheralID: peripheralID, deviceName: deviceName, wifi: false, requestsForget: requestsForget)
                } else {
                    self.disconnect(message)
                }
            }
        }
        timeout = Task {
            do { try await Task.sleep(for: .seconds(wifi && active == nil ? 5 : 18)) } catch { return }
            fail("Looking for your paired Mac…")
        }
        let accept: @MainActor @Sendable (BridgeStatus) -> Void = { [weak self, weak link] status in
            guard let self, let link, self.candidate === link, link.claimSent else { return }
            self.timeout?.cancel()
            self.timeout = nil
            self.forgetBrowser?.cancel()
            self.forgetBrowser = nil
            let old = self.active
            self.active = link
            self.candidate = nil
            old?.close()
            self.onAuthenticated(code, link.peripheral)
            self.onState(wifi ? "Connected via Wi-Fi" : "Connected via Bluetooth", true)
            self.onInitialStatus(status)
        }
        if wifi {
            forgetBrowser = RevocationAdvertisements.browse(for: RevocationNotice(code: code), onPolicyChange: { [weak link] denied in
                link?.browseDenied = denied
            }) { [weak self, weak link] in
                guard let self, let link, self.candidate === link else { return }
                self.revoked()
            }
            guard let parameters = try? TouchPairing.parameters(code: code) else { fail("Invalid pairing"); return }
            let endpoint = NWEndpoint.service(name: TouchPairing.localServiceName(code: code), type: TouchPairing.service, domain: "local.", interface: nil)
            let channel = LocalChannel(NWConnection(to: endpoint, using: parameters))
            link.local = channel
            channel.onClose = { fail("Wi-Fi disconnected") }
            channel.onFrame = { [weak self, weak link, weak channel] frame in
                guard let self, let link, let channel else { return }
                switch frame {
                case .available where self.candidate === link && !link.claimSent:
                    link.claim = { [weak channel] in channel?.send(.claim(identity)) }
                    if self.active == nil { self.commitPreparedRoute() }
                case .accepted(let status): accept(status)
                case .receipt(let receipt) where self.active === link && receipt.version == 1 && link.pending == receipt.id:
                    link.pending = nil
                    self.onReceipt(receipt)
                case .preview(let command) where self.active === link: self.onPreview(command)
                case .discard(let input) where self.active === link: self.onDiscardInput(input)
                case .pairingRevoked where self.active === link: self.revoked()
                default: channel.close(); return
                }
                channel.armTimeout(seconds: 10)
            }
            channel.start()
        } else {
            link.bluetooth = BluetoothTouchClient(onState: { [weak self, weak link] message, ready in
                MainActor.assumeIsolated {
                    guard !ready, let self, let link else { return }
                    if self.active === link || link.peripheral != nil { fail(message) }
                }
            }, onAuthenticated: { [weak self, weak link] _, id in
                guard let self, let link, self.candidate === link else { return }
                link.peripheral = id
                var request = WakeRequest(action: .getStatus)
                request.connectionAttempt = identity
                link.claimID = request.id
                link.claim = { [weak link] in link?.bluetooth?.send(request) }
                if self.active == nil { self.commitPreparedRoute() }
            }, onPreview: { [weak self, weak link] preview in
                MainActor.assumeIsolated { if let self, let link, self.active === link { self.onPreview(preview) } }
            }, onDiscardInput: { [weak self, weak link] input in
                MainActor.assumeIsolated { if let self, let link, self.active === link { self.onDiscardInput(input) } }
            }, onPairingRevoked: { [weak self, weak link] in
                guard let self, let link, self.active === link || self.candidate === link else { return }
                self.revoked()
            }, onReceipt: { [weak self, weak link] receipt in
                MainActor.assumeIsolated {
                    guard let self, let link else { return }
                    if self.candidate === link, receipt.id == link.claimID, receipt.outcome == .status, let status = receipt.status {
                        accept(status)
                    } else if self.active === link { self.onReceipt(receipt) }
                }
            })
            link.bluetooth?.connect(code: code, peripheralID: peripheralID)
        }
    }

    /// While connected, the phone calls this only after an idle status receipt.
    public func commitPreparedRoute() {
        guard let candidate, let claim = candidate.claim else { return }
        candidate.claim = nil
        candidate.claimSent = true
        claim()
    }

    public func send(_ request: WakeRequest) {
        guard let active, !isCommitting else { return }
        if let channel = active.local {
            guard active.pending == nil else { return }
            active.pending = request.id
            channel.armTimeout(seconds: request.action == .startDictation ? 8 : 5)
            channel.send(.request(request))
        } else { active.bluetooth?.send(request) }
    }

    private func clearCandidate() {
        timeout?.cancel()
        timeout = nil
        forgetBrowser?.cancel()
        forgetBrowser = nil
        let old = candidate
        candidate = nil
        old?.close()
    }
    private func reset() {
        clearCandidate()
        let old = active
        active = nil
        old?.close()
    }
    private func disconnect(_ message: String) { reset(); onState(message, false) }
    private func revoked() {
        reset()
        onPairingRevoked()
        onState("Scan the new QR code on your Mac", false)
    }
    public func stop() { disconnect("Disconnected") }
}
