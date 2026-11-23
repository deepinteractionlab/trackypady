// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Combine
import UIKit
import OSLog
@preconcurrency import AVFoundation
import VisionKit
import TouchCore
import TouchLink

@MainActor
final class TouchPhoneModel: ObservableObject {
    @Published var connected=false
    @Published var busy=false
    @Published var scanning=false
    enum ScannerState {
        case awaitingPermission, ready, denied, restricted, unavailable
    }
    @Published private(set) var scannerState: ScannerState = .awaitingPermission
    @Published var status="Scan the QR in Trackypady Bridge on your Mac."
    @Published var result="Ready when you are"
    @Published var lastEvent=""
    @Published var touchStatus=""
    @Published private var discardGate = DiscardGestureGate()
    var discardPending: Bool { discardGate.pendingID != nil }
    var discardRequestID: UUID? { discardGate.pendingID }
    @Published var queueHolding=false
    @Published var queuePending=false
    @Published private var queueContactActive=false
    @Published var queueSentWhileHeld=false
    @Published var steeringPending=false
    private let present: (PhoneSkinEvent) -> Void
    @Published var recordingPhase=DictationHold.Phase.idle
    @Published var bridgeStatus: BridgeStatus?
    var headline: String { if connected,queueHolding { return "Hold to\nQueue" };if connected,queuePending { return "Sending\nQueue" };if connected,queueSentWhileHeld { return "Queue\nsent" };if connected,wakeHold.isPending { return "Waking Codex" };if connected,discardPending { return bridgeStatus?.discardSelected == true ? "Discarding" : "Selecting draft" };return TouchPresentation.headline(connected:connected,phase:recordingPhase,status:bridgeStatus,steeringPending:steeringPending) }
    var instruction: String { if connected,queueHolding { return "Keep holding · release to cancel" };if connected,queuePending { return "Submitting the current composer" };if connected,queueSentWhileHeld { return "Release when ready" };if connected,wakeHold.isPending { return "Keep holding to dictate" };if connected,discardPending { return bridgeStatus?.discardSelected == true ? "Clearing the current draft" : "Selecting the current draft" };return TouchPresentation.instruction(connected:connected,phase:recordingPhase,status:bridgeStatus,steeringPending:steeringPending) }
    var acceptsGestures: Bool { connected && bridgeStatus != nil }
    struct PadHint {
        let text: String
        var showsProgress = false
    }
    var padHint: PadHint {
        if queueHolding { return PadHint(text: "Keep holding to Queue") }
        if queueSentWhileHeld { return PadHint(text: "Release when ready") }
        if queuePending { return PadHint(text: "Wait for submission", showsProgress: true) }
        if discardPending { return PadHint(text: "Wait for discard", showsProgress: true) }
        if steeringPending { return PadHint(text: "Wait for submission", showsProgress: true) }
        if recordingPhase == .stopping { return PadHint(text: "Stopping recording…") }
        if bridgeStatus?.dictation == .transcribing { return PadHint(text: "Swipe up to send the current draft · down to discard") }
        if recordingPhase == .starting { return PadHint(text: "Keep holding with three fingers", showsProgress: true) }
        if recordingPhase == .recording || bridgeStatus?.dictation == .recording { return PadHint(text: "Keep holding or release to stop") }
        if bridgeStatus?.discardSelected == true {
            return PadHint(text: preferences.singleFingerSwipesEnabled ? "Swipe down again to delete" : "Swipe down again with three fingers to delete")
        }
        if busy { return PadHint(text: "", showsProgress: true) }
        if bridgeStatus?.codexForeground == false { return PadHint(text: "Hold three fingers to bring Codex forward and dictate") }
        if bridgeStatus?.dictation == .ready {
            return PadHint(text: preferences.singleFingerSwipesEnabled ? "Swipe up to send · down to discard" : "Three fingers: up to send · down to discard")
        }
        return PadHint(text: "Hold with three fingers to dictate")
    }
    private var pending: WakeRequest?
    private var queuedAction: WakeRequest?
    private var statusTask: Task<Void,Never>?
    private var hold=DictationHold()
    private var wakeHold=WakeHoldHandoff()
    private var inFlightWake: WakeRequest? {
        if pending?.action == .wakeCodex { return pending }
        if queuedAction?.action == .wakeCodex { return queuedAction }
        return nil
    }
    @Published private(set) var scratchTiming = ScratchTiming.fast
    private var lastScratchTrial: String?
    private var scratchStop = ScratchStopSession()
    private let stopImpact = UIImpactFeedbackGenerator(style: .heavy)
    private var lastBridgeReceiptAt: TimeInterval?
    private var queuedStop: WakeRequest?
    private var holding=false
    private var heartbeatTask: Task<Void,Never>?
    private var lastSuccess=false
    private var combinedRecording=false
    private var haptics: TouchHaptics?
    @Published private(set) var hapticMapping = HapticMapping.defaults
    private func receiveMapping(_ value: HapticMapping) {
        guard hapticMapping != value else { return }
        hapticMapping=value;haptics?.updateMapping(value)
        PhoneTrace.event("haptic mapping applied \(value.revision)")
    }
    @Published var hapticsAvailable=false
    @Published var hapticPreviewMessage="Preview patterns from the Mac mapping table."
    private var lastPreviewCommand: UUID?
    private var previewSessionID: UUID?
    private var discardFeedback=DiscardInputFeedback()
    private var previewLooping=false
    private var previewDispatching=false
    private var previewReportingUntil: TimeInterval=0
    private var playingPreviewCue: HapticCue? {
        guard lastPreviewCommand != nil,haptics?.currentMoment == nil else { return nil }
        return haptics?.currentCue
    }
    private var reportingPreview: Bool { playingPreviewCue != nil || ProcessInfo.processInfo.systemUptime < previewReportingUntil }
    private func receivePreview(_ command: HapticPreviewCommand) {
        guard connected,active,previewSessionID == command.sessionID,lastPreviewCommand != command.id else { return }
        lastPreviewCommand=command.id
        previewLooping=command.loop;previewReportingUntil=ProcessInfo.processInfo.systemUptime+1
        defer { statusTask?.cancel();statusTask=nil;startStatusPolling() }
        if preferences.hapticsDisabled { hapticPreviewMessage = "Haptics disabled"; return }
        if command.recordingError == true {
            guard !holding, !queueHolding, !busy else { hapticPreviewMessage = "Phone is busy"; return }
            recordingErrorFeedback()
            hapticPreviewMessage = "Recording error preview requested"
        } else if let cue=command.cue {
            guard hapticsAvailable else { hapticPreviewMessage="Custom haptics unavailable";return }
            hapticPreviewMessage="Preview started: \(cue.title)\(command.reversed == true ? " · reversed" : "")\(command.loop ? " · looping" : "")"
            previewDispatching=true
            haptics?.play(cue,loop:command.loop,reversed:command.reversed == true)
            previewDispatching=false
        } else { haptics?.stop();hapticPreviewMessage="Preview stopped" }
        PhoneTrace.event("preview \(command.cue?.rawValue ?? "stop") loop=\(command.loop) reversed=\(command.reversed == true)")
    }
    // Older bridges omit preferences. Use this phone's previous values as migration defaults.
    @Published private(set) var preferences = PhonePreferences(
        singleFingerSwipesEnabled: UserDefaults.standard.object(forKey: "singleFingerSwipesEnabled") as? Bool ?? true,
        recordingHapticsEnabled: UserDefaults.standard.object(forKey: "recordingHapticsEnabled") as? Bool ?? true,
        useSystemErrorHaptic: UserDefaults.standard.bool(forKey: "useIOSErrorHaptic"),
        hapticsDisabled: UserDefaults.standard.bool(forKey: "hapticsDisabled")
    )
    private static let hapticLog=Logger(subsystem:"com.deepinteractionlab.trackypady.app",category:"Haptics")
    private func prepareHaptics() {
        guard haptics == nil else { return }
        do {
            let service=TouchHaptics(driver:try CoreHapticDriver(),mapping:hapticMapping)
            service.isMuted = preferences.hapticsDisabled
            service.onFailure={ [weak self] error in
                Self.hapticLog.error("Haptics unavailable: \(String(describing:error),privacy:.public)")
                if self?.previewDispatching == true { self?.hapticPreviewMessage="Preview could not play · try another pattern" }
            }
            haptics=service;hapticsAvailable=true
        } catch { Self.hapticLog.info("Custom haptics unavailable: \(String(describing:error),privacy:.public)") }
    }
    private func recordingErrorFeedback() {
        present(.recordingError)
        recordingErrorHaptic()
    }

    private func recordingErrorHaptic() {
        haptics?.stop()
        guard !preferences.hapticsDisabled, hapticMapping[.recordingError] != nil else { return }
        if preferences.useSystemErrorHaptic || haptics == nil { UINotificationFeedbackGenerator().notificationOccurred(.error) }
        else { haptics?.playMoment(.recordingError) }
    }
    private func swipeErrorHaptic(_ receipt: WakeReceipt) {
        guard !preferences.hapticsDisabled else { return }
        if receipt.isComposerFocusFailure || receipt.status?.codexForeground == false {
            recordingErrorHaptic()
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
    private let pairingStore=TouchPairingStore()
    @Published private(set) var hasPendingForget = false
    @Published var pairingAlert: String?
    private var forgetDelivery: Task<Void, Never>?
    private static let clearRevokedPairingKey = "clearRevokedPhonePairing"
    @Published private var savedPairing: SavedTouchPairing?
    var hasPairing: Bool { savedPairing != nil }
    @Published private var pendingPairing: SavedTouchPairing?
    @Published private(set) var macForgotPairing = false
    @Published private(set) var reconnectNeedsHelp = false
    var showsConnectionProgress: Bool {
        connected || savedPairing != nil || pendingPairing != nil
    }
    private var reconnectTask: Task<Void,Never>?
    private var routeSwitchFailed = false
    private var wifiSetupFellBack = false
    private var pendingWiFiSetup: (action: WiFiSetupAction, requestID: UUID)?
    private var wifiSetupFailure: WiFiFailureReport?
    @Published var showWiFiSettingsHelp = false
    private var connecting=false
    private var active=false
    init(present: @escaping (PhoneSkinEvent) -> Void) {
        self.present = present
        do {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--reset-phone-pairing") {
                try pairingStore.forget(.phone)
                PhoneTrace.event("Saved phone pairing cleared")
            }
            #endif
            if UserDefaults.standard.bool(forKey: Self.clearRevokedPairingKey) {
                try deleteRevokedPairing()
            } else {
                savedPairing = try pairingStore.load(.phone)
            }
            if savedPairing != nil { status="Looking for your paired Mac…" }
        } catch { status=error.localizedDescription }
    }
    private lazy var client: RacingTouchClient = makeClient()
    private func makeClient() -> RacingTouchClient {
        RacingTouchClient(onState:{ [weak self] message,ready in
        guard let self else { return }
        let wasConnected=self.connected
        if wasConnected != ready || (!ready && self.status != message) { PhoneTrace.event("Bridge ready=\(ready): \(message)") }
        self.status=message; self.connected=ready
        if ready {
            self.macForgotPairing=false
            self.reconnectNeedsHelp=false
            if !wasConnected { self.result="";self.touchStatus="";self.lastEvent="";self.previewSessionID=UUID() }
            self.connecting=false;self.reconnectTask?.cancel();self.reconnectTask=nil
        }
        if !ready {
            self.pendingWiFiSetup = nil
            self.reconnectNeedsHelp=self.active && !wasConnected
            self.present(.reset)
            self.lastBridgeReceiptAt=nil;self.previewSessionID=nil;self.lastPreviewCommand=nil;self.discardFeedback.reset()
            self.haptics?.stop()
            self.scratchStop = ScratchStopSession();self.busy=false;self.steeringPending=false;self.queuePending=false;self.queueHolding=false;self.queueContactActive=false;self.queueSentWhileHeld=false;self.discardGate=DiscardGestureGate();self.pending=nil;self.queuedAction=nil;self.resetHold();self.bridgeStatus=nil
            self.statusTask?.cancel();self.statusTask=nil
            self.connecting=false;self.scheduleReconnect()
        } else { self.startStatusPolling() }
    },onAuthenticated:{ [weak self] code,id in
        guard let self, var pairing = try? SavedTouchPairing(code: code, peripheralID: id ?? (savedPairing?.code == code ? savedPairing?.peripheralID : nil)) else { return }
        // The authenticated callback supplies a peripheral ID only for Bluetooth.
        pairing.prefersWiFi = savedPairing?.code == code ? savedPairing?.prefersWiFi : nil
        wifiSetupFellBack = pairing.prefersWiFi == true && id != nil
        routeSwitchFailed = false
        if savedPairing != pairing {
            do {
                try pairingStore.save(pairing, for: .phone)
                UserDefaults.standard.removeObject(forKey: Self.clearRevokedPairingKey)
            }
            catch { result="Connected, but pairing could not be saved: \(error.localizedDescription)" }
            savedPairing = pairing
        }
        pendingPairing = nil
    },onInitialStatus:{ [weak self] status in
        self?.applyStatus(status)
    },onPreview:{ [weak self] command in
        Task { @MainActor in self?.receivePreview(command) }
    },onDiscardInput:{ [weak self] input in
        Task { @MainActor in
            guard let self,self.connected,self.active,let moment=self.discardFeedback.receive(input) else { return }
            self.present(.draftInput(input.action))
            self.haptics?.playMoment(moment)
            PhoneTrace.event("discard input \(input.action.rawValue) \(input.requestID.uuidString.prefix(8))")
        }
    },onPairingRevoked:{ [weak self] in
        self?.forgetRevokedPairing()
    },onSwitchFailed: { [weak self] in
        self?.routeSwitchFailed = true
    },onReceipt:{ [weak self] receipt in
        Task { @MainActor in
            guard let self,let request=self.pending,request.id == receipt.id else { return }
            self.pending=nil
            if request.action == .wakeCodex || request.action == .startDictation {
                PhoneTrace.event("bridge receipt: \(request.action.rawValue) \(receipt.outcome.rawValue)")
            }
            let now = ProcessInfo.processInfo.systemUptime
            if let previous = self.lastBridgeReceiptAt, now - previous > 2 {
                PhoneTrace.event("bridge receipt gap seconds=\(String(format: "%.2f", now - previous))")
            }
            self.lastBridgeReceiptAt = now
            if let preferences = receipt.phonePreferences, preferences != self.preferences {
                self.preferences = preferences
                self.haptics?.isMuted = preferences.hapticsDisabled
                UserDefaults.standard.set(preferences.hapticsDisabled, forKey: "hapticsDisabled")
                if !preferences.recordingHapticsEnabled { self.haptics?.recordingReleased() }
            }
            if let timing = receipt.scratchTiming, self.scratchTiming != timing {
                self.scratchTiming = timing
                PhoneTrace.event("scratch timing applied \(timing.label)")
            }
            if let mapping=receipt.hapticMapping { self.receiveMapping(mapping) }
            if let status=receipt.status { self.applyStatus(status) }
            if let preview=receipt.hapticPreview { self.receivePreview(preview) }
            if request.action == .getStatus {
                if let action = receipt.wifiSetupAction { self.pendingWiFiSetup = (action, receipt.id) }
                if let queued=self.queuedAction {
                    self.queuedAction=nil;self.busy=false;self.send(queued)
                } else if self.hold.phase == .idle, !self.busy, !self.queueContactActive, !self.scratchStop.isActive,
                          self.bridgeStatus?.dictation != .recording, self.bridgeStatus?.dictation != .transcribing,
                          UIApplication.shared.applicationState == .active {
                    if let action = self.pendingWiFiSetup {
                        self.pendingWiFiSetup = nil
                        self.handleWiFiSetup(action.action, requestID: action.requestID)
                    }
                    self.client.commitPreparedRoute()
                }
                return
            }
            self.busy=false
            if request.action == .prepareResponseStop {
                PhoneTrace.event("scratch prepare receipt \(receipt.outcome.rawValue)")
                guard let id = request.scratchID else { return }
                let ready = receipt.outcome == .stopPrepared
                if !ready { self.result = receipt.message }
                self.dispatchScratchStop(self.scratchStop.prepared(id, successful: ready))
                return
            }
            if request.action == .stopResponse {
                if let direction = self.scratchStop.confirmedDirection(for: request.scratchID, receipt: receipt) {
                    self.present(.stopped(direction))
                }
                self.result = receipt.message
                if self.scratchStop.acknowledge(request.scratchID, receipt: receipt), let id = request.scratchID {
                    self.scheduleDictationAfterStop(id)
                }
                if receipt.outcome == .stopPressed && !self.preferences.hapticsDisabled {
                    self.haptics?.play(.stopComplete)
                    if self.haptics?.currentCue != .stopComplete {
                        self.stopImpact.impactOccurred(intensity: 1.0)
                        PhoneTrace.event("Stop haptic used system fallback")
                    }
                }
                return
            }
            if request.action == .discardDraft {
                let selected = receipt.outcome == .draftSelected ||
                    (receipt.outcome == .draftEditRequested && self.discardFeedback.action == .selecting)
                // Older bridges can confirm the edit without a separate input acknowledgement.
                if self.discardFeedback.action == nil {
                    if receipt.outcome == .draftSelected { self.present(.draftInput(.selecting)) }
                    if receipt.outcome == .draftDiscarded { self.present(.draftInput(.discarding)) }
                }
                if receipt.outcome == .failed { self.present(.draftFailed) }
                self.discardFeedback.reset()
                self.result=receipt.message
                if self.discardGate.finish(request.id, selected: selected) {
                    self.discard()
                    return
                }
                if receipt.outcome == .failed { self.swipeErrorHaptic(receipt) }
                return
            }
            if request.action == .sendQueue {
                self.queuePending=false
                let dispatched=receipt.submissionResult(for: .sendQueue) != .failed
                self.result=dispatched ? "Queue command sent" : receipt.message
                self.queueSentWhileHeld=dispatched && self.queueContactActive
                self.haptics?.queueHoldChanged(false)
                if dispatched { self.haptics?.playMoment(.queueComplete) }
                if !dispatched {
                    self.present(.sendFailed)
                    self.swipeErrorHaptic(receipt)
                }
                return
            }
            if request.action == .sendSteering {
                self.steeringPending=false
                let submission = receipt.submissionResult(for: .sendSteering)
                self.result = submission != .failed
                    ? "Steering command sent" : receipt.message
                if receipt.outcome == .steeringSent { self.haptics?.playMoment(.steeringSent) }
                if submission == .failed {
                    self.present(.sendFailed)
                    self.swipeErrorHaptic(receipt)
                }
                return
            }
            if request.action == .wakeCodex {
                self.lastSuccess=receipt.outcome == .foreground;self.result=receipt.message
                let wasWaiting=self.wakeHold.isPending
                if !self.lastSuccess {
                    if wasWaiting { self.recordingErrorFeedback() }
                    else if !self.preferences.hapticsDisabled { UINotificationFeedbackGenerator().notificationOccurred(.error) }
                }
                if let start=self.wakeHold.complete(receipt,stillHeld:self.holding) { self.send(start) }
                else if wasWaiting { self.resetHold() }
                return
            }
            if receipt.outcome == .failed {
                self.resetHold();self.result=receipt.message
                self.recordingErrorFeedback();return
            }
            let follow=request.action == .dictationHeartbeat ? nil : self.hold.receive(receipt)
            self.recordingPhase=self.hold.phase
            // Preserve the last action acknowledgement; heartbeats aren't new actions.
            if request.action == .startDictation { self.present(.recordingAcknowledged); self.result="Dictation started" }
            else if request.action == .stopDictation { self.result="Recording stopped" }
            if let stop=self.queuedStop ?? follow {
                self.queuedStop=nil;self.send(stop);return
            }
            if request.action == .startDictation,self.holding,self.hold.phase == .recording {
                self.startHeartbeat()
                PhoneTrace.event("recording acknowledged; cues=\(self.preferences.recordingHapticsEnabled)")
                if self.preferences.recordingHapticsEnabled {
                    self.haptics?.recordingStarted(combined: self.combinedRecording, afterStop: request.scratchID != nil)
                }
            }
            if request.action == .stopDictation {
                self.heartbeatTask?.cancel();self.heartbeatTask=nil
                self.haptics?.recordingReleased()
                // Don't inherit the idle poll's remaining 700 ms sleep after release.
                self.statusTask?.cancel();self.statusTask=nil;self.startStatusPolling()
            }
        }
        })
    }
    private func forgetRevokedPairing() {
        clearLocalPairing()
        macForgotPairing = true
    }

    func forgetMac() {
        guard savedPairing != nil || pendingPairing != nil else { return }
        if let savedPairing {
            do { try pairingStore.queuePhoneForget(savedPairing) }
            catch {
                pairingAlert = "Couldn’t save the unpair request. Unlock your iPhone and try again."
                return
            }
        }
        stopConnection()
        clearLocalPairing()
        macForgotPairing = false
        status = "Scan the QR code on your Mac"
        resumeForgetDelivery()
    }

    private func resumeForgetDelivery() {
        guard active, forgetDelivery == nil else { return }
        guard let outstanding = try? pairingStore.pendingPhoneForgets() else { return }
        hasPendingForget = !outstanding.isEmpty
        guard hasPendingForget else { return }
        forgetDelivery = Task { [weak self] in
            var index = 0
            while !Task.isCancelled, let self {
                guard let records = try? pairingStore.pendingPhoneForgets(), !records.isEmpty else { break }
                let pairing = records[index % records.count]
                var confirmed = false
                var disconnected = false
                let delivery = RacingTouchClient(onState: { _, ready in disconnected = !ready }, onAuthenticated: { _, _ in },
                    onInitialStatus: { _ in }, onPreview: { _ in }, onDiscardInput: { _ in },
                    onPairingRevoked: { confirmed = true }, onReceipt: { _ in })
                delivery.connect(code: pairing.code, peripheralID: pairing.peripheralID, preferWiFi: pairing.prefersWiFi == true, requestsForget: true)
                // Only the Bridge's authenticated revocation or its persisted proof confirms delivery.
                for _ in 0..<20 {
                    if confirmed || disconnected || Task.isCancelled { break }
                    try? await Task.sleep(for: .seconds(1))
                }
                delivery.stop()
                if confirmed { try? pairingStore.confirmPhoneForget(code: pairing.code) }
                else if !Task.isCancelled { try? await Task.sleep(for: .seconds(2)) }
                index += 1
            }
            guard !Task.isCancelled, let self else { return }
            forgetDelivery = nil
            hasPendingForget = (try? pairingStore.pendingPhoneForgets().isEmpty) != true
        }
    }

    private func clearLocalPairing() {
        reconnectNeedsHelp = false
        reconnectTask?.cancel()
        reconnectTask = nil
        savedPairing = nil
        pendingPairing = nil
        // If Keychain is temporarily unavailable, ignore the revoked item on launch.
        UserDefaults.standard.set(true, forKey: Self.clearRevokedPairingKey)
        do { try deleteRevokedPairing() }
        catch { PhoneTrace.event("Revoked pairing cleanup deferred") }
    }

    private func deleteRevokedPairing() throws {
        try pairingStore.forget(.phone)
        UserDefaults.standard.removeObject(forKey: Self.clearRevokedPairingKey)
    }

    func beginPracticeHoldFeedback(combined: Bool = false) {
        guard !preferences.hapticsDisabled else { return }
        prepareHaptics()
        if combined {
            haptics?.playMoment(.wakeInput, thenLoop: preferences.recordingHapticsEnabled ? .recordingOngoing : nil)
        } else if preferences.recordingHapticsEnabled {
            haptics?.recordingStarted(combined: false)
        }
    }

    // Also cancel a combined wake cue's queued recording loop on an early release.
    func endPracticeHoldFeedback() { haptics?.stop() }
    func playPracticeMoment(_ moment: HapticMoment) {
        guard !preferences.hapticsDisabled else { return }
        prepareHaptics()
        haptics?.playMoment(moment)
    }
    func stopPracticeFeedback() { haptics?.stop() }

    func start() { active=true;resumeForgetDelivery();reconnectIfAvailable();prepareHaptics() }
    private func reconnectIfAvailable() {
        guard active,!connected,!connecting,
              !scanning,let pairing=pendingPairing ?? savedPairing,!client.isConnecting else { return }
        connecting=true;status="Connecting to your Mac…"
        PhoneTrace.event("Bridge reconnect started")
        connect(to: pairing)
    }
    private func connect(to pairing: SavedTouchPairing) {
        wifiSetupFailure = nil
        client.connect(code: pairing.code, peripheralID: pairing.peripheralID, deviceName: UIDevice.current.name,
                       preferWiFi: pairing.prefersWiFi == true)
    }

    private func handleWiFiSetup(_ action: WiFiSetupAction, requestID: UUID) {
        guard active, connected, var pairing = savedPairing else { return }
        wifiSetupFellBack = false
        routeSwitchFailed = false
        wifiSetupFailure = nil
        switch action {
        case .tryWiFi, .useBluetooth:
            let wifi = action == .tryWiFi
            pairing.prefersWiFi = wifi
            do {
                try pairingStore.save(pairing, for: .phone)
                savedPairing = pairing
                client.switchRoute(pairing: pairing, deviceName: UIDevice.current.name, wifi: wifi, requestID: requestID)
            } catch {
                routeSwitchFailed = true
                if wifi { wifiSetupFailure = WiFiFailureReport(localNetworkDenied: false, requestID: requestID) }
            }
        case .openAppSettings:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url, options: [:]) { [weak self] opened in
                if !opened { self?.showWiFiSettingsHelp = true }
            }
        }
    }

    private func scheduleReconnect() {
        guard active,(pendingPairing ?? savedPairing) != nil else { return }
        reconnectTask?.cancel()
        reconnectTask=Task { [weak self] in
            do { try await Task.sleep(for:.seconds(2)) } catch { return }
            guard let self else { return }
            self.reconnectTask=nil;self.reconnectIfAvailable()
        }
    }
    func wake() {
        guard connected,!busy,hold.phase == .idle else { return }
        let request=WakeRequest()
        haptics?.playMoment(.wakeInput)
        send(request)
    }
    private func send(_ request: WakeRequest) {
        guard connected,!busy else { return }
        if pending?.action == .getStatus {
            queuedAction=request;busy=true;lastEvent=String(request.id.uuidString.prefix(8));return
        }
        pending=request;busy=true;lastEvent=String(request.id.uuidString.prefix(8))
        if request.action == .discardDraft { discardFeedback.begin(request.id) }
        PhoneTrace.event("send \(request.action.rawValue) \(request.id.uuidString.prefix(8))")
        client.send(request)
    }
    func handle(_ action: PadAction) {
        guard !client.isCommitting else { return }
        switch action {
        case .wake: wake()
        case .beginHold: beginHold()
        case let .endHold(cancelled): endHold(reason: cancelled ? "Touch cancelled by iOS" : "Fingers released")
        case .steer: steer()
        case .queue: queue()
        case let .queueHold(pending): queueHold(pending)
        case .queueReleased: queueRelease()
        case .discard: discard()
        case let .repeatDiscard(id): repeatDiscard(during: id)
        case let .note(message): touchStatus = message
        case let .beginScratch(id):
            guard connected, !busy, hold.phase == .idle else {
                touchStatus = connected ? "Scratch received · waiting for current action" : "Scratch received · reconnecting"
                return
            }
            if let request = scratchStop.begin(id) { send(request) }
        case let .completeScratch(id, contacts, direction):
            dispatchScratchStop(scratchStop.recognize(id, contacts: contacts, direction: direction))
        case let .releaseScratch(id):
            if scratchStop.release(id) { endHold(reason: "Scratch fingers released") }
        case let .endScratch(id, gesture):
            recordTrial(gesture)
            scratchStop.finishPan(id)
        }
    }

    private func scheduleDictationAfterStop(_ id: UUID) {
        let duration = preferences.dictationHoldDuration
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard let self, active, connected, !busy, hold.phase == .idle,
                  scratchStop.beginHeldDictation(id), let start = hold.begin(afterScratch: id) else { return }
            holding = true
            combinedRecording = false
            recordingPhase = hold.phase
            touchStatus = "Starting dictation · keep three fingers down"
            send(start)
        }
    }

    private func dispatchScratchStop(_ request: WakeRequest?) {
        guard let request else { return }
        guard connected, !busy else {
            scratchStop = ScratchStopSession()
            touchStatus = "Stop interrupted · scratch again"
            return
        }
        stopImpact.prepare()
        send(request)
    }

    private func recordTrial(_ gesture: ScratchGesture) {
        if let duration = gesture.lastWindowDuration {
            let measured = String(format: "%.2f s", duration)
            lastScratchTrial = "\(measured) · \(gesture.recognized ? "matched" : "outside range") · target \(gesture.timing.label)"
        } else {
            lastScratchTrial = "\(gesture.strokes) of \(ScratchGesture.requiredStrokes) strokes · target \(gesture.timing.label)"
        }
    }
    func steer() {
        guard connected,!busy,hold.phase == .idle,!steeringPending,
              bridgeStatus?.dictation.permitsComposerCommands == true else { touchStatus="Swipe up received · wait for Ready";return }
        steeringPending=true;touchStatus="Swipe up"
        present(.steer)
        send(WakeRequest(action:.sendSteering))
    }
    func queueHold(_ isPending: Bool) {
        if isPending,(!connected || busy || hold.phase != .idle || bridgeStatus?.dictation.permitsComposerCommands != true) {
            present(.queueHoldEnded)
            queueHolding=false;haptics?.queueHoldChanged(false);return
        }
        let changed=queueHolding != isPending
        if isPending,!queueContactActive { queueSentWhileHeld=false;queueContactActive=true }
        queueHolding=isPending
        // A stopped/reset engine must not cause this per-frame callback to resume an old hold.
        if changed {
            if isPending { present(.queueHoldBegan) }
            haptics?.queueHoldChanged(isPending)
        }
    }
    func queue() {
        haptics?.queueHoldChanged(false)
        queueHolding=false
        guard connected,!busy,hold.phase == .idle,!steeringPending,!queuePending,
              bridgeStatus?.dictation.permitsComposerCommands == true else {
            present(.queueHoldEnded)
            return
        }
        present(.queueCommitted)
        queueContactActive=true;queueSentWhileHeld=false
        queuePending=true;touchStatus="Swipe up and hold"
        send(WakeRequest(action:.sendQueue))
    }
    func queueRelease() {
        present(.queueHoldEnded)
        haptics?.queueHoldChanged(false)
        queueHolding=false;queueContactActive=false;queueSentWhileHeld=false
    }
    func discard() {
        guard connected,!busy,hold.phase == .idle,!steeringPending,
              bridgeStatus?.dictation.permitsComposerCommands == true else { touchStatus="Swipe down received · wait for Ready";return }
        let request = WakeRequest(action:.discardDraft)
        discardGate.begin(request.id)
        touchStatus="Swipe down"
        send(request)
    }
    func repeatDiscard(during id: UUID) {
        if discardGate.repeatDown(during: id) { discard() }
    }
    func beginHold() {
        let age = lastBridgeReceiptAt.map { String(format: "%.2f", ProcessInfo.processInfo.systemUptime - $0) } ?? "unknown"
        PhoneTrace.event("dictation hold: connected=\(connected) busy=\(busy) phase=\(hold.phase) lastReceiptSeconds=\(age)")
        guard connected else { touchStatus="Connect to Mac before holding";return }
        let wake=inFlightWake
        guard !busy || wake != nil else { touchStatus="Wait for the current action, then hold again";return }
        guard bridgeStatus?.dictation != .transcribing else { touchStatus="Wait for transcription, then hold again";return }
        guard let request=hold.begin() else { touchStatus="Release your fingers before a new hold";return }
        holding=true;recordingPhase=hold.phase;combinedRecording = wake != nil
        touchStatus="Three fingers held"
        // Ask the Mac for its current foreground state on every hold; the last
        // Bluetooth status can predate an app switch.
        let activation = wake ?? WakeRequest(action:.wakeCodex)
        guard wakeHold.stage(request,after:activation) else { resetHold();return }
        if wake == nil { send(activation) }
    }
    func endHold(reason: String="Fingers released") {
        PhoneTrace.event("end hold: \(reason); phase=\(hold.phase.rawValue)")
        if holding { touchStatus=reason }
        holding=false;heartbeatTask?.cancel();heartbeatTask=nil
        haptics?.recordingReleased()
        if wakeHold.isPending { resetHold();return }
        // Release intent updates the UI immediately, including while start acknowledgement is pending.
        if recordingPhase == .starting || recordingPhase == .recording { recordingPhase = .stopping }
        guard let request=hold.end() else { return }
        recordingPhase=hold.phase
        if busy { queuedStop=request } else { send(request) }
    }
    private func resetHold() {
        haptics?.recordingReleased();combinedRecording=false
        wakeHold.cancel()
        holding=false;hold.reset();recordingPhase=hold.phase;queuedStop=nil
        heartbeatTask?.cancel();heartbeatTask=nil
    }
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask=Task { [weak self] in
            while !Task.isCancelled {
                guard let self,self.holding,self.hold.phase == .recording else { return }
                if !self.busy,let session=self.hold.recordingID {
                    self.send(WakeRequest(action:.dictationHeartbeat, recordingID:session, appliedPhonePreferences:self.preferences))
                }
                try? await Task.sleep(for:.seconds(1))
            }
        }
    }
    private func applyStatus(_ status: BridgeStatus) {
        let previous=bridgeStatus?.dictation
        bridgeStatus=status
        if previous == nil && acceptsGestures { PhoneTrace.event("Gesture ready: " + self.status) }
        if !discardPending, status.discardSelected == false {
            present(.selectionCleared)
        }
        if previous != .recording, status.dictation == .recording {
            present(.reset)
        }
        if previous != status.dictation { PhoneTrace.event("dictation status \(previous?.rawValue ?? "none") -> \(status.dictation.rawValue)") }
        if status.discardSelected != true,result == "Draft selected" { result="" }
        if headline == "Bring Codex\nto front",result == "Codex brought forward" { result="" }
        if previous == .transcribing,status.dictation == .ready {
            result="Transcript Done in Codex"
            haptics?.playMoment(.transcriptDone)
        }
        if previous == .transcribing,status.dictation == .unknown { result="Check Codex · transcription completion could not be confirmed" }
        if previous == .transcribing,status.dictation == .failed { result="Codex could not transcribe · check its composer" }
    }
    private func startStatusPolling() {
        guard statusTask == nil else { return }
        statusTask=Task { [weak self] in
            while !Task.isCancelled {
                guard let self,self.connected else { return }
                if !self.client.isCommitting,self.pending == nil,!self.busy,(self.hold.phase == .idle || self.reportingPreview) {
                    let preview=HapticPreviewState(enabled:self.connected,sessionID:self.previewSessionID,lastCommandID:self.lastPreviewCommand,message:self.hapticPreviewMessage,playingCue:self.playingPreviewCue,looping:self.previewLooping && self.playingPreviewCue != nil,reversed:self.playingPreviewCue != nil && self.haptics?.currentReversed == true)
                    var request=WakeRequest(action:.getStatus,hapticPreview:preview,hapticMappingRevision:self.hapticMapping.revision,appliedScratchTiming:self.scratchTiming,lastScratchTrial:self.lastScratchTrial,appliedPhonePreferences:self.preferences)
                    request.supportsWiFiSetup = true
                    request.supportsRouteSwitch = true
                    request.prefersWiFi = self.savedPairing?.prefersWiFi == true
                    request.wifiFailure = self.wifiSetupFailure ?? self.client.lastWiFiFailure
                    if self.routeSwitchFailed { request.routeSwitchFailed = true }
                    if self.wifiSetupFellBack { request.wifiSetupFellBack = true }
                    self.pending=request;self.client.send(request)
                }
                let activeTransition=self.bridgeStatus?.dictation == .transcribing || self.bridgeStatus?.dictation == .ready
                try? await Task.sleep(for:.milliseconds((activeTransition || self.reportingPreview) ? 100 : 700))
            }
        }
    }
    func scan() {
        scanning = true
        refreshScanner()
        if scannerState == .awaitingPermission {
            Task {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                refreshScanner()
            }
        }
    }
    func refreshScanner(scannerFailed: Bool = false) {
        guard scanning else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: scannerState = .awaitingPermission
        case .denied: scannerState = .denied
        case .restricted: scannerState = .restricted
        case .authorized:
            scannerState = !scannerFailed && DataScannerViewController.isSupported && DataScannerViewController.isAvailable
                ? .ready : .unavailable
        @unknown default: scannerState = .unavailable
        }
    }
    func pair(_ text: String) {
        do {
            let scanned = try TouchPairing.parseQR(text)
            let pairing = try SavedTouchPairing(code: scanned.code)
            scanning = false
            if try pairingStore.pendingPhoneForgets().contains(where: { $0.code == pairing.code }) {
                pairingAlert = "This QR code belongs to the pairing you ended. Scan the new code on your Mac."
                return
            }
            // SwiftUI can deliver a link again while starting or activating a scene.
            if connected, savedPairing?.code == pairing.code { return }
            if connecting, (pendingPairing ?? savedPairing)?.code == pairing.code { return }
            stopConnection()
            pendingPairing = pairing
            reconnectNeedsHelp=false;connecting=true
            result="Ready when you are"; lastEvent=""
            connect(to: pairing)
        } catch { status=error.localizedDescription }
    }
    func scannerDismissed() { reconnectIfAvailable() }
    private func stopConnection() {
        present(.reset)
        scratchStop = ScratchStopSession()
        previewSessionID=nil;lastPreviewCommand=nil;discardFeedback.reset()
        haptics?.stop()
        bridgeStatus = nil
        let recordingWasActive=recordingPhase != .idle
        endHold(reason:"Connection/app interrupted");client.stop();pending=nil;queuedAction=nil;busy=false;steeringPending=false;connected=false;resetHold()
        discardGate=DiscardGestureGate();queuePending=false;queueHolding=false;queueContactActive=false;queueSentWhileHeld=false
        connecting=false;reconnectTask?.cancel();reconnectTask=nil;statusTask?.cancel();statusTask=nil
        result=recordingWasActive ? "Disconnected · check Codex for the interrupted recording" : ""
    }
    func suspend() {
        active = false
        forgetDelivery?.cancel()
        forgetDelivery = nil
        stopConnection()
    }
}
