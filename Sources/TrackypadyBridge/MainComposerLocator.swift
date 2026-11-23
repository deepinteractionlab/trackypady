// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import AppKit
import ApplicationServices
import TouchCore

/// Read-only bounded discovery of the main chat input, excluding side editors
/// and question replies. It is invoked by paired-phone composer actions.
@MainActor
enum MainComposerLocator {
    struct Target { let field:AXUIElement;let scope:AXUIElement }
    struct Failure: LocalizedError {
        let message:String
        var axError: AXError? = nil
        var errorDescription:String? { message }
    }
    private static func read(_ element:AXUIElement,_ key:String) throws -> CFTypeRef? {
        var value:CFTypeRef?
        let result=AXUIElementCopyAttributeValue(element,key as CFString,&value)
        if result == .noValue || result == .attributeUnsupported { return nil }
        guard result == .success else { throw Failure(message:"Main Codex composer search unavailable (AX \(result.rawValue)) · try again", axError: result) }
        return value
    }
    private struct RendererPending: Error {}
    private static var preparedApp: NSRunningApplication?

    static func prepareForegroundRenderer(force: Bool = false) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.openai.codex", (force || app != preparedApp),
              AXIsProcessTrusted() else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard (try? read(element, kAXRoleAttribute)) as? String == kAXApplicationRole else { return }
        preparedApp = app
        if AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue) != .success {
            // Chromium can expose its web tree asynchronously after this request.
            _ = AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    static func find(in window: AXUIElement) async throws -> Target {
        // A new chat can have a fresh renderer even in the same app process.
        prepareForegroundRenderer(force: true)
        return try await discover {
            if let scope = try focusedComposerScope(in: window) {
                return try scan(scope, limit: 400)
            }
            return try scan(window)
        }
    }

    // Stopping a turn can invalidate individual elements during a scan. Start
    // from the same window each time, before any focus change or shortcut.
    static func discover<T>(timeout: Duration = .seconds(2), scan: () throws -> T) async throws -> T {
        let deadline = ContinuousClock.now + timeout
        while true {
            try Task.checkCancellation()
            do { return try scan() }
            catch let failure as Failure where failure.axError == .invalidUIElement || failure.axError == .cannotComplete {
                guard ContinuousClock.now < deadline else { throw failure }
            } catch is RendererPending {
                guard ContinuousClock.now < deadline else {
                    throw Failure(message: "Codex hasn’t exposed the chat controls yet · keep the intended chat open and try again")
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    struct SubmissionTarget {
        let button: AXUIElement
        let label: String
    }

    static func submissionTarget(in window: AXUIElement, field: AXUIElement) async throws -> SubmissionTarget {
        let composer = try await find(in: window)
        guard CFEqual(composer.field, field) else { throw Failure(message: "Codex composer changed · no command sent") }
        let labels: Set<String> = ["Send", "Steer", "Queue"]
        let search = try boundedSearch(root: composer.scope, limit: 300) { element in
            let names = try [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { try read(element, $0) as? String }
            return SearchSnapshot(matches: try read(element, kAXRoleAttribute) as? String == kAXButtonRole &&
                read(element, kAXEnabledAttribute) as? Bool == true && !labels.isDisjoint(with: names),
                children: try read(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
        }
        guard search.complete, search.matches.count == 1,
              let button = search.matches.first else { throw Failure(message: "Codex send control is unavailable · no command sent") }
        let names = try [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { try read(button, $0) as? String }
        let matches = labels.intersection(names)
        guard matches.count == 1, let label = matches.first else { throw Failure(message: "Codex send action is ambiguous · no command sent") }
        return SubmissionTarget(button: button, label: label)
    }

    static func submissionIsCurrent(_ target: SubmissionTarget) throws -> Bool {
        let names = try [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { try read(target.button, $0) as? String }
        return try read(target.button, kAXEnabledAttribute) as? Bool == true && names.contains(target.label)
    }

    static func pressSubmission(_ target: SubmissionTarget) throws {
        guard try submissionIsCurrent(target) else { throw Failure(message: "Codex send action changed · no command sent") }
        guard AXUIElementPerformAction(target.button, kAXPressAction as CFString) == .success else {
            throw Failure(message: "Codex did not acknowledge the send button press")
        }
    }

    /// Follow only the focused rich editor's ancestry, verifying both the
    /// composer container and the captured window before scanning local controls.
    private static func focusedComposerScope(in window: AXUIElement) throws -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.openai.codex" else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let raw = try read(application, kAXFocusedUIElementAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let field = raw as! AXUIElement
        guard try read(field, kAXRoleAttribute) as? String == kAXTextAreaRole,
              try read(field, kAXEnabledAttribute) as? Bool == true else { return nil }
        return try verifiedFocusedScope(field: field, window: window, same: { CFEqual($0, $1) }, classes: {
            try read($0, "AXDOMClassList") as? [String] ?? []
        }, parent: {
            guard let raw = try read($0, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return raw as! AXUIElement
        })
    }

    static func verifiedFocusedScope<Node>(field: Node, window: Node, same: (Node, Node) -> Bool,
                                          classes: (Node) throws -> [String], parent: (Node) throws -> Node?) rethrows -> Node? {
        guard var context = MainComposerSelection.FocusedEditorContext(editorClasses: try classes(field)) else { return nil }
        var node = field
        var scope: Node?
        for _ in 0..<32 {
            guard let ancestor = try parent(node) else { return nil }
            node = ancestor
            if same(node, window) { return scope }
            if scope == nil, let matches = context.inspect(ancestorClasses: try classes(node)) {
                guard matches else { return nil }
                scope = node
            }
        }
        return nil
    }

    /// An exposed WebArea can still be empty while a switched chat mounts.
    /// Never turn a partial tree or ambiguous controls into permission to act.
    static func resolveScan(_ nodes: [MainComposerSelection.Node], complete: Bool) throws -> MainComposerSelection.Target {
        if let target = MainComposerSelection.resolve(nodes, complete: complete) { return target }
        if complete, !nodes.contains(where: { $0.editor || $0.recorderControl || $0.attachmentControl }) { throw RendererPending() }
        if !complete {
            throw Failure(message: "Chat control search reached its limit · click the main chat input and try again")
        }
        throw Failure(message: "Cannot identify the main Codex chat composer · no command sent (editors \(nodes.filter(\.editor).count), recorder controls \(nodes.filter(\.recorderControl).count), attachment controls \(nodes.filter(\.attachmentControl).count))")
    }

    private static func scan(_ window: AXUIElement, limit: Int = 1800) throws -> Target {
        var elements=[window],indices:[UInt:[Int]]=[CFHash(window):[0]],nodes:[MainComposerSelection.Node]=[]
        func index(_ element:AXUIElement) -> Int {
            let hash=CFHash(element)
            if let known=indices[hash]?.first(where:{ CFEqual(elements[$0],element) }) { return known }
            let id=elements.count;elements.append(element);indices[hash,default:[]].append(id);return id
        }
        var cursor=0
        while cursor<elements.count,cursor<limit {
            let element=elements[cursor]
            AXUIElementSetMessagingTimeout(element,0.1)
            let role=try read(element,kAXRoleAttribute) as? String
            let children=try (read(element,kAXChildrenAttribute) as? [AXUIElement] ?? []).map(index)
            var names=Set<String>(),editor=false,rich=false
            if [kAXButtonRole,"AXPopUpButton","AXMenuButton"].contains(role ?? "") {
                names=Set(try [kAXTitleAttribute,kAXDescriptionAttribute,kAXHelpAttribute].compactMap { try read(element,$0) as? String })
            }
            if role == kAXTextAreaRole,try read(element,kAXEnabledAttribute) as? Bool == true {
                editor=true
                let classes=try read(element,"AXDOMClassList") as? [String] ?? []
                rich=classes.contains("ProseMirror")
            }
            nodes.append(.init(children:children,editor:editor,richText:rich,
                recorderControl:!names.isDisjoint(with:DictationReadiness.startLabels.union(DictationReadiness.busyLabels)),attachmentControl:names.contains("Add files and more"),
                broadContainer:role == kAXWindowRole || role == "AXWebArea" || role == kAXApplicationRole))
            cursor+=1
        }
        let target = try resolveScan(nodes, complete: cursor == elements.count)
        return Target(field:elements[target.field],scope:elements[target.scope])
    }
}
