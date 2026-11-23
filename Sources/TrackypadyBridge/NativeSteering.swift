// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import AppKit
import ApplicationServices
import TouchCore

/// User-triggered native composer command. No draft text is logged, transported or copied to the clipboard.
@MainActor
final class NativeSteering {
    private var sending=false
    private var sentUntil: Date?
    var discardIsSelected: Bool {
        guard let target=try? focusedComposer(),!target.text.isEmpty,let range=try? selectedRange(target) else { return false }
        return DiscardSelection.action(textUTF16Length:target.text.utf16.count,location:range.location,length:range.length) == .deleteSelection
    }
    var submission: BridgeStatus.Submission? {
        if let sentUntil,Date()<sentUntil { return .sent }
        return nil
    }
    private func activateForSwipeIfNeeded(_ request: WakeRequest, _ activateCodex: @MainActor (UUID) async -> WakeReceipt) async -> WakeReceipt? {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.openai.codex" {
            let activation = await activateCodex(request.id)
            guard activation.outcome == .foreground else { return activation }
            guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.openai.codex" else {
                return WakeReceipt(id:request.id,outcome:.failed,message:TouchPresentation.swipeFocusWarning,failureReason:.composerFocus)
            }
            do {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                guard let window = try value(element, kAXFocusedWindowAttribute as CFString),
                      CFGetTypeID(window) == AXUIElementGetTypeID() else {
                    return WakeReceipt(id:request.id,outcome:.failed,message:"Open the intended Codex chat window")
                }
                _ = try await focusComposer(in: window as! AXUIElement)
            } catch { return WakeReceipt(id:request.id,outcome:.failed,message:TouchPresentation.swipeFocusWarning,failureReason:.composerFocus) }
        }
        return nil
    }
    func send(_ request: WakeRequest,shortcut: @MainActor () -> CodexShortcuts.Binding,dictation: BridgeStatus.Dictation,activateCodex: @MainActor (UUID) async -> WakeReceipt, connectionIsCurrent: @MainActor () -> Bool) async -> WakeReceipt {
        let isQueue=request.action == .sendQueue
        let label=isQueue ? "Queue" : "Steering"
        func failure(_ message: String, reason: WakeReceipt.FailureReason = .other) -> WakeReceipt {
            WakeReceipt(id: request.id, outcome: .failed, message: message, failureReason: reason)
        }
        guard !sending else { return failure("Wait for the current composer action to finish") }
        guard AXIsProcessTrusted() else { return failure("Enable Accessibility for Trackypady Bridge in System Settings, then try again") }
        guard dictation.permitsComposerCommands else {
            return failure("Finish dictation and check Codex before sending")
        }
        sending=true
        defer { sending=false }
        if let problem = await activateForSwipeIfNeeded(request, activateCodex) { return problem }
        await prepareAccessibility()
        guard connectionIsCurrent() else { return failure("Phone disconnected") }
        let target: Target
        guard let focused = try? focusedComposer(), isMainChatInput(focused.field) else { return failure(TouchPresentation.swipeFocusWarning, reason: .composerFocus) }
        target = focused
        guard !target.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return failure("Add a prompt in the Codex composer before swiping up") }
        guard !MacModifierState.hasPressedKeys else {
            return failure("Release the Mac modifier keys before sending")
        }
        sentUntil=nil
        let shortcut = shortcut()
        if shortcut.requiresRestart {
            return failure("Restart Codex to apply the saved \(label) shortcut")
        }
        guard shortcut.chord != nil || shortcut.usesComposerControls else {
            return failure("Review the \(label) shortcut in Trackypady Bridge Setup")
        }
        do {
            let control = shortcut.usesComposerControls
                ? try await MainComposerLocator.submissionTarget(in: target.window, field: target.field) : nil
            guard connectionIsCurrent() else { return failure("Phone disconnected") }
            guard !MacModifierState.hasPressedKeys else { return failure("Release the Mac modifier keys before sending") }
            // Resolve focus again after asynchronous discovery, before dispatching once.
            let current=try focusedComposer()
            guard CFEqual(current.field,target.field),CFEqual(current.window,target.window),current.text == target.text else {
                return failure("Codex composer changed · review it before swiping again")
            }
            var chord = shortcut.chord
            if let control {
                switch CodexDefaultSubmission.plan(button: control.label, queue: isQueue,
                    alternateAvailable: shortcut.alternateSubmitChord != nil) {
                case .pressButton:
                    try MainComposerLocator.pressSubmission(control)
                    sentUntil=Date().addingTimeInterval(1)
                    return WakeReceipt(id:request.id,outcome:isQueue ? .queueSent : .steeringSent,message:"\(label) command sent")
                case .alternateShortcut:
                    guard try MainComposerLocator.submissionIsCurrent(control) else { return failure("Codex send action changed · no command sent") }
                    chord = shortcut.alternateSubmitChord
                case .unavailable:
                    return failure(shortcut.alternateUnavailableReason ?? "Codex’s alternate send action is unavailable")
                }
            }
            guard let shortcut = chord, shortcut.key != nil else { return failure("A composer shortcut needs a key") }
            let events = try shortcut.tapEvents()
            for event in events { event.post(tap:.cghidEventTap) }
            sentUntil=Date().addingTimeInterval(1)
            return WakeReceipt(id:request.id,outcome:isQueue ? .queueSent : .steeringSent,message:"\(label) command sent")
        } catch { return failure(error.localizedDescription) }
    }
    func discard(_ request: WakeRequest,dictation: BridgeStatus.Dictation,activateCodex: @MainActor (UUID) async -> WakeReceipt, connectionIsCurrent: @MainActor () -> Bool,onInput: @MainActor (DiscardInputAcknowledgement.Action)->Void = { _ in }) async -> WakeReceipt {
        func failure(_ message: String, reason: WakeReceipt.FailureReason = .other) -> WakeReceipt {
            WakeReceipt(id: request.id, outcome: .failed, message: message, failureReason: reason)
        }
        guard !sending else { return failure("Wait for the current composer action to finish") }
        guard AXIsProcessTrusted() else { return failure("Enable Accessibility for Trackypady Bridge in System Settings, then try again") }
        guard dictation.permitsComposerCommands else { return failure("Finish dictation and check Codex before discarding") }
        guard !MacModifierState.hasPressedKeys else { return failure("Release the Mac modifier keys before discarding") }
        sending=true
        defer { sending=false }
        if let problem = await activateForSwipeIfNeeded(request, activateCodex) { return problem }
        guard connectionIsCurrent() else { return failure("Phone disconnected") }
        do {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.openai.codex",
                  let target = try? focusedComposer(),
                  isMainChatInput(target.field) else {
                return failure(TouchPresentation.swipeFocusWarning, reason: .composerFocus)
            }
            guard !target.text.isEmpty else { return failure("No draft to discard") }
            let initialRange = try selectedRange(target)
            guard let action=DiscardSelection.action(textUTF16Length:target.text.utf16.count,location:initialRange.location,length:initialRange.length) else {
                return failure("Codex text selection is invalid · draft was not changed")
            }
            if action == .selectAll {
                // With no selection, select all. Never synthesize Command+A on a positional keyboard.
                let rangeName=kAXSelectedTextRangeAttribute as CFString
                var settable: DarwinBoolean=false
                let support=AXUIElementIsAttributeSettable(target.field,rangeName,&settable)
                guard support == .success,settable.boolValue else {
                    return failure("Codex composer text selection is unavailable (AX \(support.rawValue)) · draft was not discarded")
                }
                var fullRange=CFRange(location:0,length:target.text.utf16.count)
                guard let selection=AXValueCreate(.cfRange,&fullRange) else {
                    return failure("Could not prepare draft text selection")
                }
                onInput(.selecting)
                let result=AXUIElementSetAttributeValue(target.field,rangeName,selection)
                guard result == .success else {
                    return failure("Codex composer text selection failed (AX \(result.rawValue)) · draft was not discarded")
                }
                var selectionConfirmation=StopConfirmation(maxObservations:20)
                for _ in 0..<20 {
                    // Selection acknowledgement may precede the updated AX range.
                    let range=try? selectedRange(target)
                    let observation: StopConfirmation.Observation = range.map {
                        DiscardSelection.isComplete(text:target.text,location:$0.location,length:$0.length) ? .stopped : .recording
                    } ?? .unavailable
                    if selectionConfirmation.observe(observation) == .confirmed {
                        return WakeReceipt(id:request.id,outcome:.draftSelected,message:"Draft selected")
                    }
                    try? await Task.sleep(for:.milliseconds(50))
                }
                return WakeReceipt(id:request.id,outcome:.draftEditRequested,message:"Selection requested · confirmation unavailable")
            }
            // Any existing selection, including a manual/partial one, is eligible.
            // Revalidate the exact range and text before unmodified Delete.
            let verifiedRange=try selectedRange(target)
            guard !MacModifierState.hasPressedKeys,verifiedRange.location == initialRange.location,verifiedRange.length == initialRange.length else {
                return failure("Codex selection changed · draft was not discarded")
            }
            guard let deleteDown=CGEvent(keyboardEventSource:nil,virtualKey:51,keyDown:true),
                  let deleteUp=CGEvent(keyboardEventSource:nil,virtualKey:51,keyDown:false) else {
                return failure("Could not prepare draft discard")
            }
            let expected=(target.text as NSString).replacingCharacters(in:NSRange(location:initialRange.location,length:initialRange.length),with:"")
            deleteDown.flags=[];deleteUp.flags=[]
            onInput(.discarding)
            deleteDown.post(tap:.cghidEventTap);deleteUp.post(tap:.cghidEventTap)
            var confirmation=StopConfirmation(maxObservations:30)
            for attempt in 0..<30 {
                if attempt>0 { try? await Task.sleep(for:.milliseconds(50)) }
                let text=try? discardResultText(target)
                let observation: StopConfirmation.Observation = text.map { DiscardSelection.matchesAfterDelete(observed:$0,expected:expected) ? .stopped : .recording } ?? .unavailable
                if confirmation.observe(observation) == .confirmed {
                    sentUntil=nil
                    return WakeReceipt(id:request.id,outcome:.draftDiscarded,message:expected.trimmingCharacters(in:.newlines).isEmpty ? "Draft discarded" : "Selected text deleted")
                }
            }
            return WakeReceipt(id:request.id,outcome:.draftEditRequested,message:"Delete requested · confirmation unavailable")
        } catch { return failure(error.localizedDescription.replacingOccurrences(of:"swiping up",with:"discarding").replacingOccurrences(of:TouchPresentation.foregroundWarning,with:"Bring Codex chat forward before discarding.")) }
    }
    private func discardResultText(_ target: Target) throws -> String {
        // Refresh the AX wrapper after an edit while preserving the original target identity.
        if let current=try? focusedComposer(),CFEqual(current.window,target.window),CFEqual(current.field,target.field) {
            return current.text
        }
        return try submittedComposerText(target)
    }
    private func selectedRange(_ target: Target) throws -> CFRange {
        let current=try focusedComposer()
        guard CFEqual(current.field,target.field),CFEqual(current.window,target.window),current.text == target.text,
              let raw=try value(current.field,kAXSelectedTextRangeAttribute as CFString),CFGetTypeID(raw) == AXValueGetTypeID() else {
            throw Problem(message:"Codex composer changed · text was not changed")
        }
        let selected=raw as! AXValue
        var range=CFRange(location:kCFNotFound,length:0)
        guard AXValueGetType(selected) == .cfRange,AXValueGetValue(selected,.cfRange,&range),
              range.location>=0,range.length>=0,range.location<=target.text.utf16.count,
              range.length<=target.text.utf16.count-range.location else {
            throw Problem(message:"Codex text selection is unavailable · text was not changed")
        }
        return range
    }
    private func prepareAccessibility() async {
        MainComposerLocator.prepareForegroundRenderer(force: true)
        // Electron exposes a newly mounted chat asynchronously.
        try? await Task.sleep(for: .milliseconds(50))
    }
    // Verify the focused editor locally using the main composer body and its thread or new-chat container. Side-panel
    // editors can also be ProseMirror fields, so the editor class alone is insufficient.
    private func isMainChatInput(_ field: AXUIElement) -> Bool {
        func classes(_ element: AXUIElement) -> [String] {
            (try? value(element, "AXDOMClassList" as CFString)) as? [String] ?? []
        }
        guard var context = MainComposerSelection.FocusedEditorContext(editorClasses: classes(field)) else { return false }
        var node = field
        for _ in 0..<16 {
            guard let parent = try? value(node, kAXParentAttribute as CFString),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            node = parent as! AXUIElement
            if let matched = context.inspect(ancestorClasses: classes(node)) { return matched }
        }
        return false
    }
    /// Dictation always targets the main chat input, regardless of current editor focus.
    func focusComposer(in expectedWindow: AXUIElement) async throws -> AXUIElement {
        let target=try await MainComposerLocator.find(in:expectedWindow)
        guard let app=NSWorkspace.shared.frontmostApplication,app.bundleIdentifier == "com.openai.codex" else { throw Problem(message:TouchPresentation.foregroundWarning) }
        let element=AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element,0.1)
        guard let window=try value(element,kAXFocusedWindowAttribute as CFString),CFEqual(window,expectedWindow) else { throw Problem(message:"Codex window changed · try again in the intended chat") }
        if let focused=try value(element,kAXFocusedUIElementAttribute as CFString),CFEqual(focused,target.field) { return target.scope }
        let result=AXUIElementSetAttributeValue(target.field,kAXFocusedAttribute as CFString,kCFBooleanTrue)
        guard result == .success else { throw Problem(message:"Could not focus the main Codex composer (AX \(result.rawValue))") }
        for _ in 0..<8 {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  let window=try value(element,kAXFocusedWindowAttribute as CFString),CFEqual(window,expectedWindow) else { throw Problem(message:"Codex window changed · dictation not started") }
            if let focused=try value(element,kAXFocusedUIElementAttribute as CFString),CFEqual(focused,target.field) { return target.scope }
            try await Task.sleep(for:.milliseconds(50))
        }
        throw Problem(message:"Main Codex composer focus was not confirmed · dictation not started")
    }
    private struct Target { let field: AXUIElement;let window: AXUIElement;let text: String }
    private struct Problem: LocalizedError { let message: String;var transient=false;var errorDescription: String? { message } }
    private func submittedComposerText(_ target: Target) throws -> String {
        guard let app=NSWorkspace.shared.frontmostApplication,app.bundleIdentifier == "com.openai.codex" else {
            throw Problem(message:"Submission window is no longer in front")
        }
        let element=AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element,0.1)
        guard let window=try value(element,kAXFocusedWindowAttribute as CFString),CFGetTypeID(window) == AXUIElementGetTypeID(),
              CFEqual(window,target.window),
              (try value(target.field,kAXRoleAttribute as CFString) as? String) == kAXTextAreaRole,
              let text=try composerText(target.field) else {
            throw Problem(message:"Original composer clearance is unavailable")
        }
        return text
    }
    private func composerText(_ field: AXUIElement) throws -> String? {
        guard let raw = try value(field, kAXValueAttribute as CFString) as? String else { return nil }
        if raw.isEmpty { return raw }
        // Chromium includes the rendered hint in AXValue. A real draft can
        // contain the same words, so identify the sole placeholder paragraph.
        if let children = (try? value(field, kAXChildrenAttribute as CFString)) as? [AXUIElement],
           children.count == 1,
           let classes = (try? value(children[0], "AXDOMClassList" as CFString)) as? [String],
           classes.contains("placeholder"), classes.contains("before:composer-placeholder") {
            return ""
        }
        return raw
    }
    private func value(_ element: AXUIElement,_ name: CFString) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let result=AXUIElementCopyAttributeValue(element,name,&value)
        guard result == .success else { throw Problem(message:"Codex composer could not read \(name) (AX \(result.rawValue)) · click its input field and try again",transient:result == .invalidUIElement || result == .cannotComplete) }
        return value
    }
    private func focusedComposer() throws -> Target {
        guard let app=NSWorkspace.shared.frontmostApplication,app.bundleIdentifier == "com.openai.codex" else {
            throw Problem(message:TouchPresentation.foregroundWarning)
        }
        let element=AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element,0.1)
        guard let rawWindow=try value(element,kAXFocusedWindowAttribute as CFString),CFGetTypeID(rawWindow) == AXUIElementGetTypeID(),
              let rawField=try value(element,kAXFocusedUIElementAttribute as CFString),CFGetTypeID(rawField) == AXUIElementGetTypeID() else {
            throw Problem(message:"Click the Codex composer before swiping up")
        }
        let field=rawField as! AXUIElement
        AXUIElementSetMessagingTimeout(field,0.1)
        guard (try value(field,kAXRoleAttribute as CFString) as? String) == kAXTextAreaRole,
              (try value(field,kAXEnabledAttribute as CFString) as? Bool) == true,
              let text=try composerText(field) else {
            throw Problem(message:"Click the Codex composer before swiping up")
        }
        return Target(field:field,window:rawWindow as! AXUIElement,text:text)
    }
}
