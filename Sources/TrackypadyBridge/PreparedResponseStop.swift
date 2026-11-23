// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import AppKit
import ApplicationServices
import Foundation

/// Capture only the foreground window and response-log boundary. The Stop
/// shortcut must work even when the chat's composer tree is unavailable.
@MainActor
struct PreparedResponseStop {
    let id: UUID
    private let pid: pid_t
    private let binding: CodexStopBinding.Selection
    private let bundleURL: URL?
    private let launchedAt: Date?
    private let checkpoint: ResponseLogCheckpoint
    private let application: AXUIElement
    private let window: AXUIElement
    private let document: String?

    init(id: UUID, binding: CodexStopBinding.Selection) throws {
        guard AXIsProcessTrusted() else {
            throw MainComposerLocator.Failure(message: "Enable Accessibility for Trackypady Bridge in System Settings")
        }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        guard apps.count == 1, let app = apps.first else {
            throw MainComposerLocator.Failure(message: "Cannot identify one running Codex app")
        }
        guard binding.isCurrent(bundleURL: app.bundleURL, launchedAt: app.launchDate) else {
            throw CodexStopBinding.Failure.changed
        }
        self.binding = binding
        self.bundleURL = app.bundleURL
        self.launchedAt = app.launchDate
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw MainComposerLocator.Failure(message: "Bring the intended Codex chat forward before stopping")
        }
        guard let path = GlobalDictationObservation.currentLog(pid: app.processIdentifier) else {
            throw MainComposerLocator.Failure(message: "Cannot verify the current Codex run")
        }
        do { checkpoint = try ResponseLogCheckpoint(path: path) }
        catch { throw MainComposerLocator.Failure(message: "Cannot read the Codex run log") }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.1)
        guard let raw = try Self.read(application, kAXFocusedWindowAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            throw MainComposerLocator.Failure(message: "Open the intended Codex chat window")
        }
        let window = raw as! AXUIElement
        self.id = id
        self.pid = app.processIdentifier
        self.application = application
        self.window = window
        self.document = try Self.read(window, kAXDocumentAttribute) as? String
    }

    var path: CodexStopBinding.Path { binding.path }

    func send(using shortcut: ResponseStopShortcut, connectionIsCurrent: () -> Bool) async throws -> Bool {
        try await shortcut.send(isCurrent: {
            guard connectionIsCurrent(), binding.isCurrent(bundleURL: bundleURL, launchedAt: launchedAt), !MacModifierState.hasPressedKeys,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let current = try Self.read(application, kAXFocusedWindowAttribute),
                  CFEqual(current, window),
                  try Self.read(window, kAXDocumentAttribute) as? String == document else { return false }
            return try checkpoint.stillCurrent(at: GlobalDictationObservation.currentLog(pid: pid))
        }, pressEscape: Self.pressEscape)
    }

    private static func read(_ element: AXUIElement, _ key: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        if result == .noValue || result == .attributeUnsupported { return nil }
        guard result == .success else {
            let field = key == kAXFocusedWindowAttribute ? "focused window" : "window document"
            throw MainComposerLocator.Failure(message: "Stop window check failed: \(field) (AX \(result.rawValue))", axError: result)
        }
        return value
    }

    private static func pressEscape() throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) else {
            throw MainComposerLocator.Failure(message: "Could not prepare the Stop shortcut")
        }
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

/// One deliberate Escape/confirmation sequence, never an automatic retry.
/// Revalidate after the renderer has had a chance to show its confirmation.
@MainActor
final class ResponseStopShortcut {
    private var sending = false
    func send(isCurrent: () throws -> Bool, pressEscape: () throws -> Void,
              waitForConfirmation: () async throws -> Void = { try await Task.sleep(for: .milliseconds(150)) }) async throws -> Bool {
        guard !sending else { return false }
        sending = true
        defer { sending = false }
        try Task.checkCancellation()
        guard try isCurrent() else { return false }
        try pressEscape()
        try await waitForConfirmation()
        try Task.checkCancellation()
        guard try isCurrent() else { return false }
        try pressEscape()
        return true
    }
}

/// Evidence gathered between touch-down and Stop. A changed log or turn invalidates the capture.
struct ResponseLogCheckpoint {
    let path: URL
    private let offset: UInt64
    private static let maximumBytes = 262_144

    init(path: URL) throws {
        self.path = path
        let file = try FileHandle(forReadingFrom: path)
        defer { try? file.close() }
        offset = try file.seekToEnd()
    }

    func stillCurrent(at currentPath: URL?) throws -> Bool {
        guard currentPath == path else { return false }
        let file = try FileHandle(forReadingFrom: path)
        defer { try? file.close() }
        let end = try file.seekToEnd()
        guard end >= offset, end - offset <= Self.maximumBytes else { return false }
        try file.seek(toOffset: offset)
        let data = try file.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count >= end - offset, data.count <= Self.maximumBytes else { return false }
        let changes = String(decoding: data, as: UTF8.self)
        return !changes.contains("method=turn/start ") && !changes.contains("turn-start config resolved")
            && !changes.contains("thread_stream_view_activity_changed")
    }
}

/// Owns the asynchronous foreground step so a cancelled or superseded request
/// cannot capture a target after activation finishes.
@MainActor
final class ResponseStopPreparation {
    private var token: UUID?
    func cancel() { token = nil }

    func capture<T>(isCurrent: () -> Bool, activate: () async throws -> Void,
                    target: () throws -> T) async throws -> T {
        let attempt = UUID()
        token = attempt
        defer { if token == attempt { token = nil } }
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        try await activate()
        try Task.checkCancellation()
        guard token == attempt, isCurrent() else { throw CancellationError() }
        return try target()
    }
}
