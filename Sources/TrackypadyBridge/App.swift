// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import AppKit
@preconcurrency import ApplicationServices
import CoreBluetooth
import CoreImage.CIFilterBuiltins
import TouchCore
import TouchLink

@MainActor
final class BridgeModel: ObservableObject {
    @Published private(set) var accessibilityAllowed = AXIsProcessTrusted()

    func refreshAccessibility() {
        let allowed = AXIsProcessTrusted()
        if accessibilityAllowed != allowed { accessibilityAllowed = allowed }
    }

    func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @Published private(set) var bluetoothAuthorization = CBManager.authorization
    @Published private(set) var bluetoothPoweredOff = false

    var bluetoothPermissionWarning: String? {
        switch bluetoothAuthorization {
        case .allowedAlways, .notDetermined: nil
        case .denied: "Permission is off in macOS."
        case .restricted: "Bluetooth access is restricted in macOS."
        @unknown default: "Couldn’t check Bluetooth permission."
        }
    }

    func refreshBluetoothPermission() {
        let authorization = CBManager.authorization
        if bluetoothAuthorization != authorization { bluetoothAuthorization = authorization }
    }

    func openBluetoothPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }

    func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    @Published var status="Starting bridge…"
    @Published var lastResult=""
    @Published var lastResultIsError=false
    @Published private(set) var events: [BridgeEvent] = []

    private func record(_ event: BridgeEvent) {
        events.insert(event, at: 0)
        if events.count > 12 { events.removeLast() }
    }

    func phoneSyncMessage(applied: Bool) -> String {
        if !phoneConnected { return "Saved on Mac" }
        return applied ? "Applied on iPhone" : "Waiting for iPhone"
    }
    @Published var qr: NSImage?
    @Published private(set) var listening = false
    private static let preferencesStore = PhonePreferencesStore(defaults: .standard)
    @Published var phonePreferences = preferencesStore.saved ?? PhonePreferences() {
        didSet { Self.preferencesStore.save(phonePreferences) }
    }
    @Published private(set) var appliedPreferences: PhonePreferences?
    private func preferencesForPhone(_ request: WakeRequest) -> PhonePreferences? {
        guard let reported = request.appliedPhonePreferences else { return nil }
        if appliedPreferences == nil {
            let saved = Self.preferencesStore.initialValue(reportedBy: reported)
            if phonePreferences != saved { phonePreferences = saved }
        }
        if appliedPreferences != reported { appliedPreferences = reported }
        return phonePreferences == reported ? nil : phonePreferences
    }
    @Published var dictateAfterStop = UserDefaults.standard.bool(forKey: "dictateAfterScratchStop") {
        didSet { UserDefaults.standard.set(dictateAfterStop, forKey: "dictateAfterScratchStop") }
    }
    @Published var scratchTiming = UserDefaults.standard.data(forKey: "liveScratchTiming")
        .flatMap { try? JSONDecoder().decode(ScratchTiming.self, from: $0) } ?? .fast {
        didSet {
            if let data = try? JSONEncoder().encode(scratchTiming) { UserDefaults.standard.set(data, forKey: "liveScratchTiming") }
        }
    }
    @Published private(set) var phoneScratchTiming: ScratchTiming?
    @Published private(set) var lastScratchTrial: String?
    private func timingForPhone(_ request: WakeRequest) -> ScratchTiming? {
        if phoneScratchTiming != request.appliedScratchTiming { phoneScratchTiming = request.appliedScratchTiming }
        if lastScratchTrial != request.lastScratchTrial { lastScratchTrial = request.lastScratchTrial }
        return phoneScratchTiming == scratchTiming ? nil : scratchTiming
    }
    @Published var phoneConnected=false
    var connectionType: String? { server.transportName }
    @Published var bridgeStatus: BridgeStatus?
    @Published private(set) var shortcuts: CodexShortcuts
    @Published private(set) var shortcutDrafts: [BridgeShortcut: String] = [:]
    @Published private(set) var shortcutError: String?
    @Published private(set) var lastShortcutPush: Date? {
        didSet { shortcutDefaults.set(lastShortcutPush, forKey: shortcutPushKey) }
    }
    private var shortcutSnapshot: CodexShortcutSetup.Snapshot?
    private var shortcutEditBases: [BridgeShortcut: [String?]] = [:]
    private var pulledDrafts: [BridgeShortcut: String] = [:]
    private let shortcutHome: URL
    private var shortcutURL: URL { shortcutHome.appendingPathComponent("keybindings.json") }

    private let shortcutDefaults: UserDefaults
    private let shortcutRestartKey: String
    private let shortcutPushKey: String
    private let codexLaunchDate: () -> Date?
    @Published private(set) var pendingShortcutRestarts: [String: Date] {
        didSet { shortcutDefaults.set(pendingShortcutRestarts, forKey: shortcutRestartKey) }
    }

    init(shortcutHome: URL = CodexShortcuts.home, shortcutDefaults: UserDefaults = .standard,
         codexLaunchDate: @escaping () -> Date? = {
             let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
             return apps.count == 1 ? apps.first?.launchDate : nil
         }) {
        self.shortcutHome = shortcutHome
        self.shortcutDefaults = shortcutDefaults
        self.codexLaunchDate = codexLaunchDate
        let profilePath = shortcutHome.resolvingSymlinksInPath().standardizedFileURL.path
        self.shortcutRestartKey = "pendingShortcutRestarts:" + profilePath
        self.shortcutPushKey = "lastShortcutPush:" + profilePath
        self.pendingShortcutRestarts = shortcutDefaults.dictionary(forKey: shortcutRestartKey) as? [String: Date] ?? [:]
        self.lastShortcutPush = shortcutDefaults.object(forKey: shortcutPushKey) as? Date
        self.shortcuts = CodexShortcuts.load(from: shortcutHome)
    }
    @Published private(set) var stopBindingStatus = "Checking…"
    private var selectedStopBinding: CodexStopBinding.Selection?
    private var stopBindingCheck: Task<Void, Never>?
    private var stopBindingObservers: [NSObjectProtocol] = []

    fileprivate func monitorStopBinding() {
        guard stopBindingObservers.isEmpty else { return }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.openai.codex" else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refreshStopBinding()
                    if !self.pendingShortcutRestarts.isEmpty { self.refreshSavedShortcuts() }
                }
            }
            stopBindingObservers.append(observer)
        }
        refreshStopBinding()
    }

    private func refreshStopBinding() {
        stopBindingCheck?.cancel()
        selectedStopBinding = nil
        stopPreparation.cancel()
        preparedStop = nil
        stopBindingStatus = "Checking…"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        guard running.count <= 1,
              let url = running.first?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            stopBindingStatus = "Couldn’t verify"
            return
        }
        stopBindingCheck = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try CodexStopBinding.select(bundleURL: url) }
            }.value
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let verification):
                let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
                if let app = apps.first, (apps.count != 1 || !verification.isCurrent(bundleURL: app.bundleURL, launchedAt: app.launchDate)) {
                    stopBindingStatus = "Couldn’t verify"
                    record(BridgeEvent("Stop shortcut check", CodexStopBinding.Failure.changed.localizedDescription, failed: true))
                } else {
                    selectedStopBinding = verification
                    stopBindingStatus = verification.path.rawValue
                }
            case .failure(let error):
                stopBindingStatus = "Couldn’t verify"
                record(BridgeEvent("Stop shortcut check", error.localizedDescription, failed: true))
            }
            if let binding = selectedStopBinding {
                record(BridgeEvent("Stop shortcut check", stopBindingStatus, stopPath: binding.path))
            }
        }
    }


    var hasShortcutEdits: Bool { !shortcutEditBases.isEmpty }
    var canEditShortcuts: Bool { shortcutSnapshot != nil }
    var shortcutEditsConflict: Bool {
        shortcutEditBases.keys.contains(where: shortcutEditConflicts)
    }

    private func shortcutEditConflicts(_ command: BridgeShortcut) -> Bool {
        guard let snapshot = shortcutSnapshot, let original = shortcutEditBases[command] else { return false }
        return savedKeys(for: command, in: snapshot) != original
    }

    private func savedKeys(for command: BridgeShortcut, in snapshot: CodexShortcutSetup.Snapshot) -> [String?] {
        let rows = snapshot.rows(command)
        if rows.isEmpty, command == .dictate, configuredShortcut(command).chord != nil {
            return [shortcuts[command].display]
        }
        return rows.map { $0["key"] as? String }
    }

    func shortcutEditBase(for command: BridgeShortcut) -> [String?]? {
        shortcutEditBases[command] ?? shortcutSnapshot.map { savedKeys(for: command, in: $0) }
    }

    func editShortcut(_ command: BridgeShortcut, to value: String, basedOn original: [String?]) {
        if value == pulledDrafts[command] {
            shortcutEditBases.removeValue(forKey: command)
        } else if shortcutEditBases[command] == nil {
            shortcutEditBases[command] = original
        }
        shortcutDrafts[command] = value
    }

    func discardShortcutEdits() {
        shortcutEditBases.removeAll()
        refreshSavedShortcuts(force: true)
        shortcutDrafts = pulledDrafts
    }

    func isShortcutConfigured(_ command: BridgeShortcut) -> Bool {
        configuredShortcut(command).chord != nil
    }

    func shortcutAttentionDetail(_ command: BridgeShortcut, includeRepairGuidance: Bool = false) -> String? {
        if includeRepairGuidance && shortcutEditConflicts(command) {
            return "This shortcut changed in Codex. Click Discard changes, edit the shortcut again, then click Push changes to Codex."
        }
        if shortcutNeedsRestart(command) { return "Codex restart required" }
        guard !isShortcutConfigured(command) else { return nil }
        guard let snapshot = shortcutSnapshot else { return "Couldn’t verify the saved shortcut." }
        let rows = snapshot.rows(command)
        if rows.count > 1 { return "Multiple bindings in Codex. Edit them in Codex Settings." }

        let saved = rows.first?["key"] as? String
        let suggested = CodexShortcutSetup.bindings.first { $0.command == command.rawValue }?.key
        if let key = saved ?? (rows.isEmpty ? suggested : nil),
           let chord = ShortcutChord(key), let owner = snapshot.conflict(chord, for: command.rawValue) {
            let ownerTitle = BridgeShortcut(rawValue: owner)?.title ?? owner
            return includeRepairGuidance
                ? "\(key) is used by \(ownerTitle). Click Change to choose another, then click Push changes to Codex."
                : "\(key) is assigned to \(ownerTitle)."
        }
        if let saved {
            return includeRepairGuidance
                ? "\(saved) can’t be used here. Click Change to choose another, then click Push changes to Codex."
                : "\(saved) is unavailable."
        }
        if rows.isEmpty {
            return includeRepairGuidance ? "No shortcut assigned. Click Change to add one, then click Push changes to Codex." : "No shortcut assigned in Codex."
        }
        return includeRepairGuidance ? "Disabled in Codex. Click Change to assign a shortcut, then click Push changes to Codex." : "Disabled in Codex."
    }

    func shortcutNeedsRestart(_ command: BridgeShortcut) -> Bool {
        pendingShortcutRestarts[command.rawValue] != nil
    }

    func shortcutForDispatch(_ command: BridgeShortcut) -> CodexShortcuts.Binding {
        refreshSavedShortcuts()
        if shortcutNeedsRestart(command) {
            return .init(display: "Restart required", chord: nil, requiresRestart: true)
        }
        return configuredShortcut(command)
    }

    private func configuredShortcut(_ command: BridgeShortcut) -> CodexShortcuts.Binding {
        let binding = shortcuts[command]
        guard shortcutSnapshot != nil, !binding.usesComposerControls, !binding.usesToggleDictation else {
            return .init(display: "Shortcut unassigned", chord: nil)
        }
        return binding
    }
    @Published var discardPending=false
    @Published var queuePending=false
    @Published var previewAvailable=false
    private let hapticMapping = UserDefaults.standard.data(forKey: "hapticMomentMapping")
        .flatMap { try? JSONDecoder().decode(HapticMapping.self, from: $0) } ?? .defaults
    private var previewSessionID: UUID?

    func previewRecordingError() {
        guard phoneConnected, !phonePreferences.hapticsDisabled, appliedPreferences == phonePreferences,
              let session = previewSessionID else { return }
        _ = server.sendHapticPreview(HapticPreviewCommand(sessionID: session, recordingError: true))
    }
    @Published var steeringPending=false
    @Published var pendingPhase=DictationHold.Phase.idle
    var headline: String { if phoneConnected,queuePending { return "Sending\nQueue" };if phoneConnected,discardPending { return bridgeStatus?.discardSelected == true ? "Discarding" : "Selecting draft" };return TouchPresentation.headline(connected:phoneConnected,phase:pendingPhase,status:bridgeStatus,steeringPending:steeringPending,surface:.macActivity) }
    var instruction: String { if phoneConnected,queuePending { return "Submitting the current composer" };if phoneConnected,discardPending { return bridgeStatus?.discardSelected == true ? "Clearing the current draft" : "Selecting the current draft" };return TouchPresentation.instruction(connected:phoneConnected,phase:pendingPhase,status:bridgeStatus,steeringPending:steeringPending,surface:.macActivity) }
    private let pairingStore=TouchPairingStore()
    @Published private(set) var pairedPhone: PairedPhone?
    private var secret=""
    private var notices: [RevocationNotice] = []
    @Published private(set) var dictationRecoveryID: UUID?
    private lazy var dictation=NativeDictation(dictationShortcut: { [unowned self] in
        self.shortcutForDispatch(.dictate)
    }, focusComposer:{ [unowned self] window in
        try await self.steering.focusComposer(in:window)
    }, recoveryChanged: { [weak self] in self?.dictationRecoveryID = $0 }) { [weak self] message,isError in
        self?.lastResult=message;self?.lastResultIsError=isError
    }
    private let steering=NativeSteering()
    private func currentStatus(observeTranscription: Bool=true,discardSelection: Bool?=nil,observedStatus: BridgeStatus?=nil) -> BridgeStatus {
        let d=observedStatus ?? dictation.status(observeTranscription:observeTranscription)
        // Completion feedback must not wait for an unrelated editor-selection read.
        let selection=discardSelection ?? ((d.dictation == .transcribing || d.dictation == .ready) ? nil : steering.discardIsSelected)
        return BridgeStatus(codexForeground:d.codexForeground,dictation:d.dictation,recordingID:d.recordingID,
            submission:steering.submission,discardSelected:selection)
    }
    private var preparedStop: PreparedResponseStop?
    private let stopPreparation = ResponseStopPreparation()
    private let responseStopShortcut = ResponseStopShortcut()
    private var service: WakeService?

    private func execute(_ request: WakeRequest, sessionID: UUID) async -> WakeReceipt {
        let isCurrent = { @MainActor [weak self] in self?.server.connectedSessionID == sessionID }
        guard isCurrent() else {
            return WakeReceipt(id: request.id, outcome: .failed, message: "Phone disconnected")
        }
        if request.action == .prepareResponseStop || request.action == .stopResponse {
            return await handleScratch(request, connectionIsCurrent: isCurrent)
        }
        if request.action == .getStatus {
            let observed=await dictation.statusForPolling()
            guard isCurrent() else { return WakeReceipt(id: request.id, outcome: .failed, message: "Phone disconnected") }
            let status=self.currentStatus(discardSelection:request.hapticPreview?.playingCue != nil ? false : nil,observedStatus:observed)
            let preview = request.hapticPreview
            previewSessionID = preview?.enabled == true ? preview?.sessionID : nil
            previewAvailable = previewSessionID != nil
            let mapping = request.hapticMappingRevision == hapticMapping.revision ? nil : hapticMapping
            var receipt = WakeReceipt(id:request.id,outcome:.status,message:"",status:status,hapticMapping:mapping,scratchTiming:self.timingForPhone(request),phonePreferences:self.preferencesForPhone(request))
            // TestFlight build 3 may still prefer Wi-Fi. Once it falls back to
            // Bluetooth, have it save Bluetooth for future reconnects.
            if request.supportsRouteSwitch == true, request.prefersWiFi == true {
                receipt.wifiSetupAction = .useBluetooth
            }
            return receipt
        }
        let receipt: WakeReceipt
        if request.action == .wakeCodex { receipt=await BridgeModel.activateCodex(id:request.id) }
        else if request.action == .sendSteering || request.action == .sendQueue {
            let command: BridgeShortcut = request.action == .sendQueue ? .queue : .steer
            receipt = await steering.send(request, shortcut: {
                self.shortcutForDispatch(command)
            }, dictation: self.dictation.status().dictation, activateCodex: BridgeModel.activateCodex, connectionIsCurrent: isCurrent)
        }
        else if request.action == .discardDraft {
            receipt=await steering.discard(request,dictation:self.dictation.status().dictation,activateCodex:BridgeModel.activateCodex, connectionIsCurrent:isCurrent,onInput:{ [weak self] action in
                _ = self?.server.sendDiscardInput(DiscardInputAcknowledgement(requestID:request.id,action:action))
            })
        }
        else if request.action == .startDictation, request.scratchID != nil {
            let activation = await BridgeModel.activateCodex(id: request.id)
            receipt = activation.outcome == .foreground ? await dictation.handle(request, connectionIsCurrent: isCurrent) : activation
        }
        else { receipt=await dictation.handle(request, connectionIsCurrent: isCurrent) }
        let selection: Bool? = receipt.outcome == .draftSelected ? true : receipt.outcome == .draftDiscarded ? false : nil
        let status=self.currentStatus(observeTranscription:false,discardSelection:selection)
        return WakeReceipt(id:receipt.id,outcome:receipt.outcome,message:receipt.message,status:status,phonePreferences:preferencesForPhone(request),failureReason:receipt.failureReason)
    }
    private lazy var server=makeServer()
    private func authorizePhone(_ attempt: PhoneConnectionAttempt) -> Bool {
        if attempt.requestsForget == true {
            if pairedPhone?.installation == attempt.installation {
                forgetDevice()
                record(BridgeEvent("Forget Mac", lastResultIsError ? lastResult : "iPhone ended the pairing", failed: lastResultIsError))
            }
            return false
        }
        if let pairedPhone, pairedPhone.installation != attempt.installation { return false }
        let name = attempt.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = PairedPhone(installation: attempt.installation,
                                name: name.flatMap { $0.isEmpty ? nil : $0 } ?? pairedPhone?.name ?? "iPhone",
                                pairedAt: pairedPhone?.pairedAt ?? Date())
        guard phone != pairedPhone else { return true }
        do {
            let pairing = try SavedTouchPairing(code: secret, phone: phone, notices: notices)
            try pairingStore.save(pairing, for: .bridge)
            pairedPhone = phone
            return true
        } catch {
            lastResult = error.localizedDescription
            lastResultIsError = true
            return false
        }
    }

    private func makeServer() -> DualTouchServer {
        DualTouchServer(authorizePhone: { [unowned self] in self.authorizePhone($0) }, initialStatus: { [unowned self] in self.currentStatus() }, onConnectionState: { [weak self] state in
            guard let self else { return }
            if self.status != state.message {
                self.record(BridgeEvent("Connection", state.message))
            }
            self.status = self.server.transportName.map { "Connected via " + $0 } ?? state.message
            self.phoneConnected = state == .connected
            if case let .unavailable(message) = state {
                self.lastResult = message
                self.lastResultIsError = true
            }
            if state == .connected, let id = self.server.connectedSessionID {
                self.service = WakeService { [weak self] request in
                    guard let self else { return WakeReceipt(id: request.id, outcome: .failed, message: "Bridge unavailable") }
                    return await self.execute(request, sessionID: id)
                }
            } else {
                self.service = nil
                self.appliedPreferences = nil
                self.phoneScratchTiming = nil
                self.lastScratchTrial = nil
                self.previewAvailable = false
                self.previewSessionID = nil
                self.pendingPhase = .idle
                self.steeringPending = false
                self.queuePending = false
                self.discardPending = false
                self.stopPreparation.cancel()
                self.preparedStop = nil
                self.dictation.abandon()
            }
        }, onRadioPowerOffChanged: { [weak self] poweredOff in
            guard let self else { return }
            if self.bluetoothPoweredOff != poweredOff { self.bluetoothPoweredOff = poweredOff }
            self.refreshBluetoothPermission()
        }, onRequest: { [weak self] request, reply in
            guard let self, let service = self.service, let id = self.server.connectedSessionID else { return }
            Task { @MainActor in
                guard self.server.connectedSessionID == id else { return }
                if request.action == .discardDraft { self.discardPending=true }
                if request.action == .sendQueue { self.queuePending=true }
                if request.action == .sendSteering { self.steeringPending=true }
                if request.action == .startDictation { self.pendingPhase = .starting }
                if request.action == .stopDictation { self.pendingPhase = .stopping }
                let receipt = await service.handle(request)
                guard self.server.connectedSessionID == id else { return }
                let previous=self.bridgeStatus?.dictation
                if let status=receipt.status { self.bridgeStatus=status }
                if request.action == .getStatus {
                    if receipt.status?.codexForeground == false, self.lastResult == "Codex brought forward" {
                        self.lastResult=""
                    }
                    if previous == .transcribing,receipt.status?.dictation == .ready,!self.lastResultIsError {
                        self.lastResult="Transcript Done in Codex"
                    }
                    if previous == .ready,receipt.status?.dictation == .idle,!self.lastResultIsError {
                        self.lastResult=""
                    }
                    reply(receipt);return
                }
                self.pendingPhase = .idle;self.steeringPending=false;self.queuePending=false;self.discardPending=false
                if request.action != .dictationHeartbeat || receipt.outcome == .failed {
                    self.lastResult = receipt.message
                    self.lastResultIsError = receipt.outcome == .failed
                    if receipt.outcome != .stopPressed {
                        self.record(BridgeEvent(request: request, receipt: receipt))
                    }
                }
                reply(receipt)
            }
        })
    }
    fileprivate func start() {
        guard !listening else { return }
        do {
            let pairing = try pairingStore.load(.bridge) ?? pairingStore.rotateBridgePairing()
            start(using: pairing)
        } catch {
            status="Pairing unavailable";lastResult=error.localizedDescription;lastResultIsError=true;return
        }
    }
    private func start(using pairing: SavedTouchPairing) {
        showPairing(pairing)
        listening = true
        server.start(code: pairing.code, notices: pairing.notices)
    }
    private func showPairing(_ pairing: SavedTouchPairing) {
        pairedPhone = pairing.phone
        notices = pairing.notices
        secret = pairing.code
        let filter=CIFilter.qrCodeGenerator(); filter.message=Data(TouchPairing.qrPayload(code:secret).utf8)
        qr = nil
        if let output=filter.outputImage,let cg=CIContext().createCGImage(output.transformed(by:CGAffineTransform(scaleX:7,y:7)),from:output.extent.applying(CGAffineTransform(scaleX:7,y:7))) {
            qr=NSImage(cgImage:cg,size:NSSize(width:220,height:220))
        }
    }
    fileprivate func shutDown() {
        stopPreparation.cancel()
        stopBindingCheck?.cancel()
        stopBindingObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        stopBindingObservers.removeAll()
        dictation.stopForShutdown()
        if listening { server.stop() }
    }

    func forgetDevice() {
        do {
            let replacement = try pairingStore.rotateBridgePairing()
            dictation.abandon()
            if listening {
                server.replacePairing(code: replacement.code, notices: replacement.notices)
                showPairing(replacement)
            } else {
                start(using: replacement)
            }
            lastResult = "Device forgotten"
            lastResultIsError = false
        } catch {
            lastResult = "Pairing could not be reset. The existing pairing is still valid. \(error.localizedDescription)"
            lastResultIsError = true
        }
    }
    func clearFailedDictationAfterManualCheck(_ id: UUID) {
        let result=dictation.resetAfterManualCheck(id)
        lastResult=result.message;lastResultIsError=result.isError
        record(BridgeEvent("Dictation recovery", result.message, failed: result.isError))
    }
    func setUpCodexShortcuts() {
        do {
            let snapshot = try CodexShortcutSetup.read(shortcutURL)
            let current = CodexShortcuts.load(from: shortcutHome, keybindingsData: snapshot.data ?? Data())
            var defaults: [BridgeShortcut: String] = [:]
            for binding in CodexShortcutSetup.bindings {
                guard let command = BridgeShortcut(rawValue: binding.command) else { continue }
                // Older Codex profiles can store a working hold shortcut outside the keymap.
                if command == .dictate, current[command].chord != nil, !current[command].usesToggleDictation { continue }
                defaults[command] = binding.key
            }
            _ = try CodexShortcutSetup.configure(at: shortcutURL, snapshot: snapshot, edits: defaults, fillingMissing: true)
            try pullShortcuts(force: true)
        } catch { shortcutError = error.localizedDescription }
    }

    private func pullShortcuts(force: Bool = false) throws {
        let snapshot = try CodexShortcutSetup.read(shortcutURL)
        let loaded = CodexShortcuts.load(from: shortcutHome, keybindingsData: snapshot.data ?? Data())
        // A quit or foreground switch alone doesn't tell us Codex loaded the updated file.
        // Once a newer process is running, the reloaded bindings determine Ready or Needs review.
        if !pendingShortcutRestarts.isEmpty, let launched = codexLaunchDate() {
            let remaining = pendingShortcutRestarts.filter { $0.value >= launched }
            if remaining != pendingShortcutRestarts { pendingShortcutRestarts = remaining }
        }
        if !force, let previous = shortcutSnapshot, previous.data == snapshot.data, shortcuts == loaded { return }
        shortcutSnapshot = snapshot
        shortcuts = loaded
        for command in BridgeShortcut.allCases {
            let binding = configuredShortcut(command)
            let rows = snapshot.rows(command)
            pulledDrafts[command] = binding.chord != nil ? binding.display : rows.first?["key"] as? String ?? ""
        }
        var drafts = pulledDrafts
        for command in Array(shortcutEditBases.keys) {
            if let draft = shortcutDrafts[command], draft != pulledDrafts[command] {
                drafts[command] = draft
            } else {
                shortcutEditBases.removeValue(forKey: command)
            }
        }
        shortcutDrafts = drafts
        shortcutError = nil
    }

    func refreshSavedShortcuts(force: Bool = false) {
        do { try pullShortcuts(force: force) }
        catch {
            shortcutSnapshot = nil
            let message = error.localizedDescription
            if shortcutError != message { shortcutError = message }
        }
    }

    func refreshSetupChecks() {
        refreshSavedShortcuts()
        guard stopBindingStatus != "Checking…" else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        if running.count == 1, let app = running.first,
           selectedStopBinding?.isCurrent(bundleURL: app.bundleURL, launchedAt: app.launchDate) == true { return }
        refreshStopBinding()
    }

    func pushCodexShortcuts() {
        refreshSavedShortcuts()
        guard let snapshot = shortcutSnapshot, hasShortcutEdits, !shortcutEditsConflict else { return }
        do {
            let edits = shortcutDrafts.filter { shortcutEditBases[$0.key] != nil }
            _ = try CodexShortcutSetup.configure(at: shortcutURL, snapshot: snapshot, edits: edits)
            let savedAt = Date()
            lastShortcutPush = savedAt
            var pending = pendingShortcutRestarts
            for command in edits.keys { pending[command.rawValue] = savedAt }
            pendingShortcutRestarts = pending
            try pullShortcuts(force: true)
        } catch { shortcutError = error.localizedDescription }
    }
    private func handleScratch(_ request: WakeRequest, connectionIsCurrent: () -> Bool) async -> WakeReceipt {
        do {
            if request.action == .prepareResponseStop {
                preparedStop = nil
                guard let binding = selectedStopBinding else {
                    return WakeReceipt(id: request.id, outcome: .failed, message: "Stop shortcut has not been verified · check Setup")
                }
                if let id = request.scratchID {
                    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
                    guard apps.count == 1, let app = apps.first else {
                        throw MainComposerLocator.Failure(message: "Cannot identify one running Codex app")
                    }
                    let pid = app.processIdentifier
                    preparedStop = try await stopPreparation.capture(isCurrent: {
                        connectionIsCurrent() && self.selectedStopBinding == binding &&
                        !app.isTerminated && binding.isCurrent(bundleURL: app.bundleURL, launchedAt: app.launchDate) &&
                        NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").map(\.processIdentifier) == [pid]
                    }, activate: {
                        let receipt = await Self.activateCodex(id: request.id)
                        guard receipt.outcome == .foreground else {
                            throw MainComposerLocator.Failure(message: receipt.message)
                        }
                    }, target: {
                        try PreparedResponseStop(id: id, binding: binding)
                    })
                }
                return WakeReceipt(id: request.id, outcome: preparedStop == nil ? .noActiveResponse : .stopPrepared,
                                   message: preparedStop == nil ? "No active response" : "Stop shortcut ready")
            }
            guard let capture = preparedStop, capture.id == request.scratchID else {
                return WakeReceipt(id: request.id, outcome: .noActiveResponse, message: "No matching response")
            }
            preparedStop = nil
            let pressed = try await capture.send(using: responseStopShortcut, connectionIsCurrent: connectionIsCurrent)
            if pressed {
                let receipt = WakeReceipt(id: request.id, outcome: .stopPressed, message: "")
                record(BridgeEvent(request: request, receipt: receipt, stopPath: capture.path))
            }
            return WakeReceipt(id: request.id, outcome: pressed ? .stopPressed : .noActiveResponse,
                               message: pressed ? "Sent Escape twice to the current Codex chat" : "Chat, connection or keyboard state changed · Stop shortcut cancelled",
                               dictateAfterStop: pressed && dictateAfterStop)
        } catch is CancellationError {
            return WakeReceipt(id: request.id, outcome: .failed, message: "Stop preparation interrupted · scratch again")
        } catch {
            return WakeReceipt(id: request.id, outcome: .failed, message: error.localizedDescription)
        }
    }

    func testMacWake() {
        Task {
            let request=WakeRequest()
            let receipt = await Self.activateCodex(id: request.id)
            lastResult=receipt.message;lastResultIsError=receipt.outcome == .failed
            record(BridgeEvent(request: request, receipt: receipt))
        }
    }
    private static func activateCodex(id: UUID) async -> WakeReceipt {
        let bundle="com.openai.codex"
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle {
            return WakeReceipt(id:id,outcome:.foreground,message:"Codex already in front")
        }
        guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:bundle).first,let url=app.bundleURL else {
            return WakeReceipt(id:id,outcome:.failed,message:"Open Codex on this Mac, then try again")
        }
        // Wake is macOS app activation, not a Codex thread/API command.
        // Use Launch Services activation for a command arriving while this bridge is in the background.
        let configuration=NSWorkspace.OpenConfiguration()
        configuration.activates=true
        configuration.createsNewApplicationInstance=false
        configuration.promptsUserIfNeeded=false
        let activationError: String? = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at:url,configuration:configuration) { _,error in
                continuation.resume(returning:error?.localizedDescription)
            }
        }
        if let activationError {
            return WakeReceipt(id:id,outcome:.failed,message:"Codex activation failed: \(activationError)")
        }
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle {
                return WakeReceipt(id:id,outcome:.foreground,message:"Codex brought forward")
            }
            try? await Task.sleep(for:.milliseconds(100))
        }
        return WakeReceipt(id:id,outcome:.failed,message:"macOS did not confirm Codex in the foreground")
    }
}

@MainActor
final class TouchBridgeDelegate: NSObject,NSApplicationDelegate {
    let model = BridgeModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load the current bundled artwork when an in-place development update
        // leaves Launch Services displaying an earlier or empty Dock icon.
        if let url = Bundle.main.url(forResource: "Trackypady", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
        model.monitorStopBinding()
        model.setUpCodexShortcuts()
        model.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshAccessibility()
        model.refreshBluetoothPermission()
        model.refreshSetupChecks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutDown()
    }
}

@main
struct TrackypadyBridgeApp: App {
    @NSApplicationDelegateAdaptor(TouchBridgeDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Trackypady Bridge") {
            BridgeWindow(model: delegate.model)
        }
        .defaultSize(width: 900, height: 690)
    }
}
