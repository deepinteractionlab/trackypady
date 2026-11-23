// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import AppKit
import ApplicationServices
import TouchCore

/// Product adapter invoked by the user's paired phone. No generic UI scripting endpoint.
/// Stops only the owned inline recorder, or dismisses its confirmed recovery banner.
@MainActor
final class NativeDictation {
    private let preparation = DictationPreparation()
    private var session: UUID?
    private var window: AXUIElement?
    private var recorderRoot: AXUIElement?
    private var started: Date?
    private var lease: Date?
    private var watcher: Task<Void,Never>?
    private var stopping=false
    private var finishing=false
    private var acknowledgingStart=false
    private var cleanupBegan: Date?
    private var globalRecorder: GlobalDictationObservation?
    private var confirmedGlobal=false
    private var transcriptionGlobal: GlobalDictationObservation?
    private let dictationShortcut: () -> CodexShortcuts.Binding
    private var pendingKeyUps: [CGEvent] = []
    private var confirmedInline = false
    private var usesToggleDictation = false
    private var inlineLifecycle = InlineDictationLifecycle()
    private var recordingDocument: String?

    private var manualRecoveryID: UUID? {
        didSet { if manualRecoveryID != oldValue { recoveryChanged(manualRecoveryID) } }
    }
    private let recoveryChanged: (UUID?) -> Void
    private var needsReview=false
    private var transcription=TranscriptionProgress()
    private var transcriptionWindow: AXUIElement?
    private var transcriptionRoot: AXUIElement?
    private var transcriptionID: UUID?
    private var transcriptionStarted: Date?
    private let report: (String,Bool)->Void
    private let focusComposer: @MainActor (AXUIElement) async throws -> AXUIElement
    init(dictationShortcut: @escaping () -> CodexShortcuts.Binding, focusComposer: @escaping @MainActor (AXUIElement) async throws -> AXUIElement, recoveryChanged: @escaping (UUID?) -> Void, report: @escaping (String,Bool)->Void) {
        self.dictationShortcut = dictationShortcut
        self.focusComposer=focusComposer;self.report=report;self.recoveryChanged=recoveryChanged
    }
    func handle(_ request: WakeRequest, connectionIsCurrent: @MainActor () -> Bool) async -> WakeReceipt {
        guard let id=request.recordingID else { return failed(request,"Missing recording identity") }
        do {
        switch request.action {
        case .startDictation: return try await start(request,session:id, connectionIsCurrent: connectionIsCurrent)
        case .stopDictation:
            guard session == id else { return failed(request,"No matching Project X recording") }
            return try await finish(request)
        case .dictationHeartbeat:
            guard session == id,!stopping else { return failed(request,"Recording is no longer active") }
            let active = confirmedGlobal ? globalRecorder?.poll() == .recording : try recorderRoot.map { !(try buttons(in:$0,labels:["Stop dictation"])).isEmpty } == true
            guard active else {
                if confirmedGlobal, globalRecorder?.hasLoggedFailure == true { trackTranscription() }
                clear();return failed(request,"Codex recording ended or was interrupted · check the composer")
            }
            lease=Date();return WakeReceipt(id:request.id,outcome:.dictationRecording,message:"Codex recording · keep holding")
        case .wakeCodex,.getStatus,.sendSteering,.sendQueue,.discardDraft,.prepareResponseStop,.stopResponse: return failed(request,"Wake uses the macOS activation adapter")
        }
        } catch {
            if session == id { releaseShortcut();needsReview=true;abandon() }
            return failed(request,error.localizedDescription)
        }
    }
    func resetAfterManualCheck(_ expectedID: UUID) -> (message:String,isError:Bool) {
        guard session == expectedID, manualRecoveryID == expectedID else { return ("No unresolved recording attempt",false) }
        guard needsReview, !finishing, !acknowledgingStart else { return ("Recording is still managed by the phone · release to stop first",true) }
        releaseShortcut()
        clear()
        return ("Failed attempt cleared after manual check · ready to try again",false)
    }
    func abandon() {
        preparation.cancel()
        guard session != nil else { return }
        lease=Date.distantPast
    }
    private func start(_ request: WakeRequest,session id: UUID, connectionIsCurrent: @MainActor () -> Bool) async throws -> WakeReceipt {
        guard connectionIsCurrent() else { return failed(request, "Phone disconnected") }
        if let previous = session {
            guard needsReview, !finishing, !acknowledgingStart, previous != id else {
                return failed(request, "A Project X recording is already active")
            }
            guard reviewedRecordingHasEnded() else {
                manualRecoveryID = previous
                return failed(request, "Check Codex for an active recording, then open Activity → Troubleshooting → Clear dictation cache.")
            }
            if globalRecorder?.hasLoggedFailure == true { transcriptionGlobal = globalRecorder }
            clear()
        }
        guard AXIsProcessTrusted() else {
            return failed(request,"Enable Accessibility for Trackypady Bridge in System Settings, then try again")
        }
        guard transcription.state != .transcribing else { return failed(request,"Wait for Codex to finish transcribing") }
        guard let app=NSWorkspace.shared.frontmostApplication,app.bundleIdentifier == "com.openai.codex" else {
            return failed(request,TouchPresentation.foregroundWarning)
        }
        let element=AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element,0.1)
        MainComposerLocator.prepareForegroundRenderer()
        guard let focused=attribute(element,kAXFocusedWindowAttribute),CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return failed(request,"Open the intended Codex chat window")
        }
        let focusedWindow=focused as! AXUIElement
        guard let token = preparation.begin() else { return failed(request, "Dictation is already starting") }
        defer { preparation.finish(token) }
        if let observer = transcriptionGlobal,
           observer.ownsFailedOverlay(currentLog: GlobalDictationObservation.currentLog(pid: app.processIdentifier)) {
            try await DictationRecoveryBanner.dismissIfPresent(isCurrent: {
                self.preparation.isCurrent(token) && connectionIsCurrent() &&
                    NSWorkspace.shared.frontmostApplication == app &&
                    observer.isLatestAttempt(currentLog: GlobalDictationObservation.currentLog(pid: app.processIdentifier))
            }, locate: {
                try self.recoveryDismissButton(in: element, excluding: focusedWindow)
            }, press: { button in
                guard observer.ownsFailedOverlay(currentLog: GlobalDictationObservation.currentLog(pid: app.processIdentifier)),
                      AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
                    throw DictationRecoveryBanner.Failure()
                }
            })
            transcriptionGlobal = nil
            transcription = TranscriptionProgress()
        }
        let composerRoot = try await preparation.resolve(token, connectionIsCurrent: connectionIsCurrent) {
            try await focusComposer(focusedWindow)
        }
        guard preparation.isCurrent(token), connectionIsCurrent() else { return failed(request, "Phone disconnected") }
        let controls=try recorderLabels(in:composerRoot)
        if controls.contains("Stop dictation") {
            return failed(request,"Codex already has a recording; Project X will not take it over")
        }
        let busy: Set<String>=["Cancel transcription","Cancel dictation","Preparing dictation","Finishing dictation","Starting dictation; click to cancel"]
        guard controls.isDisjoint(with:busy) else {
            return failed(request,"Wait for Codex to finish preparing or transcribing dictation")
        }
        // The native hold shortcut requires composer focus. Establish and confirm
        // it in the captured window before posting any keys; never retry the chord.
        // An inline composer Retry is also a valid start state for the native shortcut.
        let startControls=try buttons(in:composerRoot,labels:DictationReadiness.startLabels)
        let enabledLabels: Set<String>=startControls.contains(where:{ (attribute($0,kAXEnabledAttribute) as? Bool) == true }) ? controls.intersection(DictationReadiness.startLabels) : []
        guard DictationReadiness.canStart(allLabels:controls,enabledLabels:enabledLabels) else {
            return failed(request,"Codex dictation is not ready · wait for its microphone control to become available")
        }
        guard !MacModifierState.hasPressedKeys else {
            return failed(request,"Release the Mac modifier keys before phone dictation")
        }
        let binding = dictationShortcut()
        if binding.requiresRestart {
            return failed(request, "Restart Codex to apply the saved Dictate shortcut")
        }
        session=id;window=focusedWindow;recorderRoot=composerRoot;started=Date();lease=Date();stopping=false
        usesToggleDictation = binding.usesToggleDictation
        recordingDocument = attribute(focusedWindow, kAXDocumentAttribute) as? String
        globalRecorder = usesToggleDictation ? nil : GlobalDictationObservation(pid: app.processIdentifier)
        do { try await pressShortcut(binding.chord, connectionIsCurrent: connectionIsCurrent) }
        catch { clear();return failed(request,error.localizedDescription) }
        acknowledgingStart=true
        defer { acknowledgingStart=false }
        watchLease()
        let deadline=Date().addingTimeInterval(4)
        var lastControls=Set<String>()
        var unavailableReads=0
        repeat {
            guard connectionIsCurrent() else {
                releaseShortcut()
                needsReview = true
                abandon()
                return failed(request, "Phone disconnected during dictation start")
            }
            do {
                let phase = globalRecorder?.poll()
                if phase == .cancelled {
                    clear()
                    return failed(request,"Dictation cancelled in Codex")
                }
                if phase == .failed, globalRecorder?.hasLoggedFailure == true {
                    confirmedGlobal = true
                    trackTranscription()
                    clear()
                    return failed(request, "Codex dictation failed to start · hold again for a fresh recording")
                }
                confirmedGlobal = phase == .recording
                if !confirmedGlobal { lastControls=try recorderLabels(in:composerRoot) }
                if confirmedGlobal || lastControls.contains("Stop dictation") {
                    guard session == id,!stopping else { return failed(request,"Recording ended before start was acknowledged") }
                    confirmedInline = !confirmedGlobal
                    transcriptionGlobal = nil
                    transcription = TranscriptionProgress()
                    lease=Date()
                    return WakeReceipt(id:request.id,outcome:.dictationRecording,message:"Codex recording · keep holding")
                }
            } catch let error as ScanFailure where error.transient { unavailableReads+=1 }
            try? await Task.sleep(for:.milliseconds(100))
        } while Date()<deadline
        releaseShortcut();needsReview=true;abandon()
        let observed=lastControls.sorted().joined(separator:", ")
        return failed(request,"Shortcut released · Codex did not confirm recording within 4s. Last controls: \(observed.isEmpty ? "unavailable" : observed). Transient reads: \(unavailableReads).")
    }

    private func finish(_ request: WakeRequest) async throws -> WakeReceipt {
        stopping=true;finishing=true;cleanupBegan=Date()
        defer { finishing=false }
        releaseShortcut()
        var confirmation=StopConfirmation()
        for _ in 0..<20 {
            let observation: StopConfirmation.Observation
            do { observation=try releaseAndCheckRecorder() ? .stopped : .recording }
            catch let error as ScanFailure where error.transient { observation = .unavailable }
            switch confirmation.observe(observation) {
            case .confirmed:
                if globalRecorder?.poll() == .cancelled {
                    transcription = TranscriptionProgress()
                    clear()
                    return WakeReceipt(id:request.id,outcome:.dictationStopped,message:"Dictation cancelled in Codex")
                }
                trackTranscription()
                clear()
                return WakeReceipt(id:request.id,outcome:.dictationStopped,message:"Recording finished · transcript is being prepared in Codex")
            case .unconfirmed: break
            case .pending:
                try? await Task.sleep(for:.milliseconds(100))
                continue
            }
            break
        }
        // Keep the owner/window until the watchdog can stop a delayed start. Never toggle Dictate again.
        needsReview=true;lease=Date.distantPast
        return failed(request,"Stop was not confirmed · check Codex; cleanup is still pending")
    }
    private func reviewedRecordingHasEnded() -> Bool {
        if let observer = globalRecorder {
            _ = observer.poll()
            if confirmedGlobal || observer.hasObservedAttempt {
                var pid: pid_t = 0
                guard let window, AXUIElementGetPid(window, &pid) == .success else { return false }
                return observer.confirmsFinishedAttempt(currentLog: GlobalDictationObservation.currentLog(pid: pid))
            }
        }
        // Only the original inline recorder can establish readiness for an inline attempt.
        guard confirmedInline, let recorderRoot, let labels = try? recorderLabels(in: recorderRoot),
              let starts = try? buttons(in: recorderRoot, labels: DictationReadiness.startLabels),
              starts.contains(where: { attribute($0, kAXEnabledAttribute) as? Bool == true }) else { return false }
        return DictationReadiness.canStart(allLabels: labels, enabledLabels: labels.intersection(DictationReadiness.startLabels))
    }

    private func releaseAndCheckRecorder() throws -> Bool {
        releaseShortcut()
        if usesToggleDictation { try stopOwnedInlineRecorder() }
        if needsReview { return reviewedRecordingHasEnded() }
        if confirmedGlobal {
            let phase = globalRecorder?.poll()
            return phase == .stopping || phase == .completed || phase == .cancelled || (phase == .failed && globalRecorder?.hasLoggedFailure == true)
        }
        guard let recorderRoot else { return false }
        return try buttons(in:recorderRoot,labels:["Stop dictation","Starting dictation; click to cancel"]).isEmpty
    }
    func stopForShutdown() {
        releaseShortcut()
        if usesToggleDictation { try? stopOwnedInlineRecorder() }
    }
    private func stopOwnedInlineRecorder() throws {
        guard session != nil, inlineLifecycle.canStop,
              let window, let recorderRoot,
              attribute(window, kAXDocumentAttribute) as? String == recordingDocument else { return }
        let stops = try buttons(in: recorderRoot, labels: ["Stop dictation"])
        guard stops.count == 1, attribute(stops[0], kAXEnabledAttribute) as? Bool == true else { return }
        // Press only Stop on the confirmed recorder we started. Never toggle again,
        // retry a press, or send a shortcut into whichever app happens to be frontmost.
        guard inlineLifecycle.claimStop() else { return }
        confirmedInline = true
        guard AXUIElementPerformAction(stops[0], kAXPressAction as CFString) == .success else {
            throw ScanFailure(message: "Could not stop the recording · check Codex")
        }
    }
    private func watchLease() {
        watcher?.cancel()
        let owner = session
        watcher=Task { [weak self] in
            var confirmation=StopConfirmation(maxObservations:10)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, let owner, self.session == owner else { return }
                guard !self.finishing,!self.acknowledgingStart else { continue }
                let now=Date()
                guard now.timeIntervalSince(self.lease ?? .distantPast)>4 || now.timeIntervalSince(self.started ?? now)>90 else { continue }
                self.stopping=true
                if self.cleanupBegan == nil { self.cleanupBegan=now }
                do {
                    let observation: StopConfirmation.Observation
                    do { observation=try self.releaseAndCheckRecorder() ? .stopped : .recording }
                    catch let error as ScanFailure where error.transient { observation = .unavailable }
                    if confirmation.observe(observation) == .confirmed {
                        self.trackTranscription()
                        self.report("Recording finished · review the transcript in Codex",false)
                        self.clear();return
                    }
                    if now.timeIntervalSince(self.cleanupBegan ?? now)>5 {
                        self.needsReview=true
                        self.report("Shortcut released · recording state could not be confirmed; check Codex",true)
                        return
                    }
                } catch {
                    self.needsReview=true
                    self.report("Shortcut released · recording state could not be confirmed; check Codex",true)
                    return
                }
            }
        }
    }
    private func trackTranscription() {
        transcriptionGlobal = confirmedGlobal ? globalRecorder : nil
        transcriptionWindow=window;transcriptionRoot=recorderRoot;transcriptionID=session;transcriptionStarted=Date();transcription.begin()
    }
    /// Confirm idle locally instead of waiting for another phone/Bluetooth poll.
    func statusForPolling() async -> BridgeStatus {
        MainComposerLocator.prepareForegroundRenderer()
        let snapshot=status()
        guard snapshot.dictation == .transcribing,transcription.needsIdleConfirmation else { return snapshot }
        let id=transcriptionID
        do { try await Task.sleep(for:.milliseconds(50)) }
        catch { return status(observeTranscription:false) }
        guard transcriptionID == id,session == nil else { return status(observeTranscription:false) }
        return status()
    }
    func status(observeTranscription: Bool=true) -> BridgeStatus {
        transcription.advance()
        if observeTranscription,(transcription.state == .transcribing || transcription.state == .failed),let window=transcriptionRoot ?? transcriptionWindow {
            if transcription.state == .transcribing,Date().timeIntervalSince(transcriptionStarted ?? .distantPast)>30 {
                // Recording already stopped. Retire the stale transcription indicator.
                transcription = TranscriptionProgress()
            } else if let transcriptionGlobal {
                switch transcriptionGlobal.poll() {
                case .cancelled: transcription = TranscriptionProgress()
                case .completed: transcription.observe(.idle)
                case .failed: transcription.observe(.failed)
                default: transcription.observe(.busy)
                }
            } else {
                do {
                    let names=try recorderLabels(in:window)
                    let busy: Set<String>=["Cancel transcription","Cancel dictation","Preparing dictation","Finishing dictation","Starting dictation; click to cancel","Stop dictation"]
                    if !names.isDisjoint(with:busy) {
                        if transcription.state == .failed { transcriptionStarted=Date() }
                        transcription.observe(.busy)
                    }
                    else if names.contains("Retry dictation") { transcription.observe(.failed) }
                    else if names.contains("Dictate") || names.contains("Start dictation") { transcription.observe(.idle) }
                    else { transcription.observe(.unavailable) }
                } catch { transcription.observe(.unavailable) }
            }
        }
        return BridgeStatus(codexForeground:NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.openai.codex",
            dictation:session != nil ? (needsReview ? .unknown : .recording) : transcription.state,
            recordingID:session ?? transcriptionID)
    }
    private func recoveryDismissButton(in app: AXUIElement, excluding chat: AXUIElement) throws -> AXUIElement? {
        guard let windows = try scanAttribute(app, kAXWindowsAttribute) as? [AXUIElement],
              windows.contains(where: { CFEqual($0, chat) }) else { throw DictationRecoveryBanner.Failure() }
        var target: AXUIElement?
        for window in windows where !CFEqual(window, chat) {
            let title = try scanAttribute(window, kAXTitleAttribute) as? String
            let document = try scanAttribute(window, kAXDocumentAttribute) as? String
            guard DictationRecoveryBanner.isRecorderWindow(title: title, document: document) else { continue }
            let dismiss = try buttons(in: window, labels: ["Dismiss"])
            let retry = try buttons(in: window, labels: ["Retry"])
            if dismiss.isEmpty && retry.isEmpty { continue }
            guard dismiss.count == 1, retry.count == 1, target == nil,
                  try scanAttribute(dismiss[0], kAXEnabledAttribute) as? Bool == true else {
                throw DictationRecoveryBanner.Failure()
            }
            target = dismiss[0]
        }
        return target
    }

    private func recorderLabels(in root: AXUIElement) throws -> Set<String> {
        let expected: Set<String>=["Dictate","Start dictation","Stop dictation","Starting dictation; click to cancel","Cancel transcription","Cancel dictation","Preparing dictation","Finishing dictation","Retry dictation"]
        var found: Set<String>=[]
        let scan=try boundedSearch(root:AXNode(element:root),limit:1800) { node in
            let element=node.element
            let role=try scanAttribute(element,kAXRoleAttribute) as? String
            let names: [String]
            if role == kAXButtonRole {
                names=try [kAXTitleAttribute,kAXDescriptionAttribute,kAXHelpAttribute].compactMap { try scanAttribute(element,$0) as? String }
            } else { names=[] }
            found.formUnion(names.filter { expected.contains($0) })
            let children=(try scanAttribute(element,kAXChildrenAttribute) as? [AXUIElement]) ?? []
            return SearchSnapshot(matches:false,children:children.map { AXNode(element:$0) })
        }
        guard scan.complete else { throw ScanFailure(message:"Transcription state scan was incomplete") }
        return found
    }
    private func clear() {
        releaseShortcut()
        manualRecoveryID=nil;confirmedInline=false;usesToggleDictation=false;inlineLifecycle=InlineDictationLifecycle();recordingDocument=nil
        globalRecorder=nil;confirmedGlobal=false
        watcher?.cancel();watcher=nil;session=nil;window=nil;recorderRoot=nil;started=nil;lease=nil;stopping=false;needsReview=false;cleanupBegan=nil
    }
    private func failed(_ request: WakeRequest,_ message: String) -> WakeReceipt {
        WakeReceipt(id:request.id,outcome:.failed,message:message)
    }
    private func pressShortcut(_ chord: ShortcutChord?, connectionIsCurrent: @MainActor () -> Bool) async throws {
        guard let chord else {
            throw ScanFailure(message: "Review the Dictate shortcut in Trackypady Bridge Setup")
        }
        let events = try chord.holdEvents()
        let owner = session
        for (down, up) in events {
            guard session == owner, connectionIsCurrent() else { throw CancellationError() }
            pendingKeyUps.append(up)
            down.post(tap: .cghidEventTap)
            if down.type == .flagsChanged { try await Task.sleep(for: .milliseconds(15)) }
        }
        if usesToggleDictation { inlineLifecycle.didDispatch(); releaseShortcut() }
    }
    private func releaseShortcut() {
        // Release exactly the keys posted, even if the layout or bindings changed during the hold.
        for event in pendingKeyUps.reversed() { event.post(tap: .cghidEventTap) }
        pendingKeyUps.removeAll()
    }
    private func attribute(_ element: AXUIElement,_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success else { return nil }
        return value
    }
    private struct AXNode: Hashable {
        let element: AXUIElement
        static func ==(lhs: Self,rhs: Self) -> Bool { CFEqual(lhs.element,rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }
    private struct ScanFailure: LocalizedError {
        let message: String
        var transient=false
        var errorDescription: String? { message }
    }
    private func scanAttribute(_ element: AXUIElement,_ name: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let result=AXUIElementCopyAttributeValue(element,name as CFString,&value)
        if result == .noValue || result == .attributeUnsupported { return nil }
        guard result == .success else {
            throw ScanFailure(message:"Codex control scan could not read \(name) (AX \(result.rawValue))",transient:result == .invalidUIElement || result == .cannotComplete)
        }
        return value
    }
    private func buttons(in root: AXUIElement,labels: Set<String>) throws -> [AXUIElement] {
        let scan=try boundedSearch(root:AXNode(element:root),limit:1800) { node in
            let element=node.element
            var matches=false
            if (try scanAttribute(element,kAXRoleAttribute) as? String) == kAXButtonRole {
                let names=try [kAXTitleAttribute,kAXDescriptionAttribute,kAXHelpAttribute].compactMap { try scanAttribute(element,$0) as? String }
                matches=names.contains(where:{ labels.contains($0) })
            }
            let children=(try scanAttribute(element,kAXChildrenAttribute) as? [AXUIElement]) ?? []
            return SearchSnapshot(matches:matches,children:children.map { AXNode(element:$0) })
        }
        guard scan.complete else {
            throw ScanFailure(message:"Codex control scan reached its \(scan.visited)-element limit · control uniqueness/state could not be established")
        }
        return scan.matches.map(\.element)
    }
}

/// A delayed recording can become visible after the phone disconnects. Keep
/// ownership after dispatch so cleanup can stop it once, even without a start receipt.
struct InlineDictationLifecycle {
    private var dispatched = false
    private var stopClaimed = false
    var canStop: Bool { dispatched && !stopClaimed }
    mutating func didDispatch() { dispatched = true }
    mutating func claimStop() -> Bool {
        guard canStop else { return false }
        stopClaimed = true
        return true
    }
}
