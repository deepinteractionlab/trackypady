// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation
@preconcurrency import Network
import OSLog
import TouchCore

@MainActor
public final class DualTouchServer {
    public typealias RequestHandler = @MainActor (WakeRequest, @escaping @Sendable (WakeReceipt) -> Void) -> Void
    private let onState: (BridgeConnectionState) -> Void
    private let onRadioPowerOffChanged: @MainActor (Bool) -> Void
    private let onRequest: RequestHandler
    private let authorizePhone: (PhoneConnectionAttempt) -> Bool
    private let initialStatus: () -> BridgeStatus
    private var owner: TouchRoute?
    private var ownerAttempt: PhoneConnectionAttempt?
    public var connectedSessionID: UUID? { owner?.id }
    public var connectedPhoneName: String? { ownerAttempt?.deviceName }
    public var isConnectedViaBluetooth: Bool {
        if case .bluetooth = owner { return true }
        return false
    }
    public var transportName: String? { owner?.label }
    private let forgetAdvertisements = RevocationAdvertisements()
    private var notices: [RevocationNotice] = []
    private var listener: NWListener?
    private var retry: Task<Void, Never>?
    private var pairingReplacement: Task<Void, Never>?
    private var channels: [UUID: LocalChannel] = [:]

    public init(authorizePhone: @escaping @MainActor (PhoneConnectionAttempt) -> Bool,
                initialStatus: @escaping @MainActor () -> BridgeStatus,
                onConnectionState: @escaping @MainActor (BridgeConnectionState) -> Void,
                onRadioPowerOffChanged: @escaping @MainActor (Bool) -> Void = { _ in },
                onRequest: @escaping RequestHandler) {
        self.authorizePhone = authorizePhone
        self.initialStatus = initialStatus
        self.onState = onConnectionState
        self.onRadioPowerOffChanged = onRadioPowerOffChanged
        self.onRequest = onRequest
    }

    private lazy var bluetooth = makeBluetoothServer()
    private func makeBluetoothServer() -> BluetoothTouchServer {
        BluetoothTouchServer(onConnectionState: { [weak self] state in
            guard let self else { return }
            if case .bluetooth = self.owner, self.bluetooth.connectedSessionID == nil {
                self.releaseOwner()
            } else if self.owner == nil, state != .connected {
                self.onState(state)
            }
        }, onRadioPowerOffChanged: onRadioPowerOffChanged, onRequest: { [weak self] request, reply in
            guard let self, let id = self.bluetooth.connectedSessionID else { return }
            // A BLE welcome can reach the phone after Wi-Fi wins. Only a request claims BLE.
            guard self.claim(.bluetooth(id), attempt: request.connectionAttempt) else {
                self.bluetooth.rejectSession()
                return
            }
            self.onRequest(request, reply)
        })
    }

    private func claim(_ route: TouchRoute, attempt: PhoneConnectionAttempt?) -> Bool {
        guard pairingReplacement == nil else { return false }
        if owner == route { return true }
        guard let attempt, authorizePhone(attempt) else { return false }
        if let owner {
            guard let previous = ownerAttempt,
                  previous.installation == attempt.installation, previous.sequence < attempt.sequence else { return false }
            // iOS may keep a terminated process's TCP connection alive until our watchdog.
            // Invalidate the old action generation before accepting the new one.
            switch owner {
            case .local(let id): channels[id]?.close()
            case .bluetooth: bluetooth.rejectSession()
            }
        }
        ownerAttempt = attempt
        owner = route
        onState(.connected)
        return true
    }
    private func releaseOwner() {
        owner = nil
        ownerAttempt = nil
        onState(.disconnected)
    }

    public func start(code: String, notices: [RevocationNotice] = []) {
        self.notices = notices
        bluetooth.start(code: code, notices: notices)
    }

    public func enableWiFi(code: String) {
        guard listener == nil else { return }
        retry?.cancel()
        listen(code: code)
    }

    public func disableWiFi() {
        retry?.cancel()
        forgetAdvertisements.stop()
        listener?.cancel()
        listener = nil
        for channel in Array(channels.values) { channel.close() }
    }
    private func listen(code: String) {
        do {
            let listener = try NWListener(using: TouchPairing.parameters(code: code, allowEthernet: true))
            listener.service = NWListener.Service(name: TouchPairing.localServiceName(code: code), type: TouchPairing.service)
            self.listener = listener
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                MainActor.assumeIsolated {
                    guard let self, let listener, self.listener === listener else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let self, let listener, self.listener === listener else { return }
                    if case .ready = state, let port = listener.port {
                        self.forgetAdvertisements.publish(self.notices, port: port.rawValue)
                    }
                    if case .failed(let error) = state {
                        self.forgetAdvertisements.stop()
                        Logger().notice("Local listener failed: \(error.localizedDescription, privacy: .public)")
                        self.listener = nil
                        listener.cancel()
                        self.retryListen(code: code)
                    }
                }
            }
            listener.start(queue: .main)
        } catch { retryListen(code: code) }
    }
    private func retryListen(code: String) {
        retry?.cancel()
        retry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.listen(code: code)
        }
    }
    func accept(_ connection: NWConnection) {
        guard channels.count < 4 else { connection.cancel(); return }
        let channel = LocalChannel(connection)
        channels[channel.id] = channel
        channel.onReady = { [weak channel] in channel?.send(.available) }
        channel.onClose = { [weak self, weak channel] in
            guard let self, let channel else { return }
            self.channels[channel.id] = nil
            if self.owner == .local(channel.id) { self.releaseOwner() }
        }
        var pending: UUID?
        channel.onFrame = { [weak self, weak channel] frame in
            guard let self, let channel else { return }
            guard self.pairingReplacement == nil else { return }
            let route = TouchRoute.local(channel.id)
            switch frame {
            case .claim(let attempt) where self.owner != route:
                guard self.claim(route, attempt: attempt) else { channel.close(); return }
                channel.send(.accepted(self.initialStatus()))
            case .request(let request) where self.owner == route && pending == nil && request.version == 1:
                pending = request.id
                self.onRequest(request) { [weak channel] receipt in
                    Task { @MainActor in
                        guard let channel, self.owner == route, receipt.id == pending else { return }
                        pending = nil
                        channel.armTimeout(seconds: 10)
                        channel.send(.receipt(receipt))
                    }
                }
            default: channel.close(); return
            }
            channel.armTimeout(seconds: 10)
        }
        channel.start()
    }
    public func stop() {
        pairingReplacement?.cancel()
        pairingReplacement = nil
        retry?.cancel()
        forgetAdvertisements.stop()
        listener?.cancel()
        listener = nil
        for channel in Array(channels.values) { channel.close() }
        bluetooth.stop()
    }

    /// Called after the replacement credential has been saved. Revoke command
    /// access immediately and give only the former owner time to receive notice.
    public func replacePairing(code: String, notices: [RevocationNotice] = []) {
        retry?.cancel()
        forgetAdvertisements.stop()
        listener?.cancel()
        listener = nil
        let previousOwner = owner
        if previousOwner != nil { releaseOwner() }
        for channel in Array(channels.values) where previousOwner != .local(channel.id) {
            channel.close()
        }

        let noticeQueued: Bool
        switch previousOwner {
        case .local(let id):
            bluetooth.stop()
            noticeQueued = channels[id]?.send(.pairingRevoked) == true
        case .bluetooth:
            noticeQueued = bluetooth.retirePairing()
        case nil:
            noticeQueued = false
        }
        guard noticeQueued else {
            stop()
            start(code: code, notices: notices)
            return
        }
        pairingReplacement = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self else { return }
            self.pairingReplacement = nil
            self.stop()
            self.start(code: code, notices: notices)
        }
    }
    public func sendHapticPreview(_ command: HapticPreviewCommand) -> Bool {
        switch owner {
        case .local(let id): return channels[id]?.send(.preview(command)) == true
        case .bluetooth: return bluetooth.sendHapticPreview(command)
        case nil: return false
        }
    }
    public func sendDiscardInput(_ input: DiscardInputAcknowledgement) -> Bool {
        switch owner {
        case .local(let id): return channels[id]?.send(.discard(input)) == true
        case .bluetooth: return bluetooth.sendDiscardInput(input)
        case nil: return false
        }
    }
}
