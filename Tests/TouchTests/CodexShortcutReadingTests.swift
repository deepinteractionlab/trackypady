// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
#if os(macOS)
import XCTest
import CoreGraphics
@testable import TrackypadyBridge

final class CodexShortcutReadingTests: XCTestCase {
    func testSetupFillsAvailableBindingsAndPushRejectsStaleEdits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("keybindings.json")
        XCTAssertNil(try CodexShortcutSetup.read(url).data)
        let original = Data(#"[{"command":"other","key":"Option+S","extra":42},{"command":"composer.queue","key":null}]"#.utf8)
        try original.write(to: url)
        let snapshot = try CodexShortcutSetup.read(url)
        let issues = try CodexShortcutSetup.configure(at: url, snapshot: snapshot,
            edits: [.dictate: "Ctrl+Alt+Shift+D", .steer: "Alt+S", .queue: "Ctrl+Q"], fillingMissing: true)
        XCTAssertEqual(issues.count, 1)
        let next = try CodexShortcutSetup.read(url)
        XCTAssertEqual(next.rows(.dictate).first?["key"] as? String, "Ctrl+Alt+Shift+D")
        XCTAssertTrue(next.rows(.queue).first?["key"] is NSNull)
        XCTAssertTrue(next.rows(.steer).isEmpty)
        XCTAssertEqual(next.entries.first?["extra"] as? Int, 42)
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("keybindings.json.backup-") })
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertThrowsError(try CodexShortcutSetup.configure(at: url, snapshot: snapshot, edits: [.steer: "Ctrl+S"]))
        XCTAssertThrowsError(try CodexShortcutSetup.configure(at: url, snapshot: next, edits: [.steer: "Ctrl+D", .queue: "Control+D"]))
        XCTAssertEqual(try Data(contentsOf: url), next.data)
        _ = try CodexShortcutSetup.configure(at: url, snapshot: next, edits: [.queue: "Ctrl+Q"])
        XCTAssertEqual(CodexShortcuts.load(from: dir)[.queue].display, "Ctrl+Q")
    }

    func testRefreshReadsEditsAndNeverModifiesCodexFiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("keybindings.json")
        XCTAssertTrue(CodexShortcuts.load(from: home)[.steer].usesComposerControls)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let original = Data(#"[{"command":"composer.steer","key":"CmdOrCtrl+Enter"}]"#.utf8)
        try original.write(to: file)
        let first = CodexShortcuts.load(from: home)
        XCTAssertEqual(first[.steer].chord?.flags, .maskCommand)
        XCTAssertEqual(try Data(contentsOf: file), original)
        let changed = Data(#"[{"command":"composer.steer","key":"Alt+F5"},{"command":"composer.queue","key":null}]"#.utf8)
        try changed.write(to: file)
        let second = CodexShortcuts.load(from: home)
        XCTAssertEqual(second[.steer].chord?.key, "f5")
        XCTAssertNil(second[.queue].chord)
        XCTAssertEqual(try Data(contentsOf: file), changed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), ["keybindings.json"])
        try Data("bad JSON".utf8).write(to: file)
        XCTAssertNil(CodexShortcuts.load(from: home)[.steer].chord)
    }

    func testDisabledVoiceOverridesLegacyAndConflictsAreNotSent() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"globalDictationHotkey":"RightAlt"}"#.utf8).write(to: home.appendingPathComponent(".codex-global-state.json"))
        XCTAssertEqual(CodexShortcuts.load(from: home)[.dictate].chord?.modifiers.first?.code, 61)
        let bindings = #"[{"command":"globalDictationHold","key":null},{"command":"composer.steer","key":"Alt+S"},{"command":"other","key":"Option+S"},{"command":"composer.queue","key":"Cmd+K Cmd+Q"}]"#
        try Data(bindings.utf8).write(to: home.appendingPathComponent("keybindings.json"))
        let loaded = CodexShortcuts.load(from: home)
        for command in BridgeShortcut.allCases { XCTAssertNil(loaded[command].chord) }
    }

    func testFreshInstallDefaultsAndCustomOverrides() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let fresh = CodexShortcuts.load(from: home)
        XCTAssertEqual(fresh[.dictate].chord, ShortcutChord("Cmd+Shift+D"))
        XCTAssertTrue(fresh[.dictate].usesToggleDictation)
        XCTAssertTrue(fresh[.steer].usesComposerControls)
        XCTAssertEqual(fresh[.queue].alternateSubmitChord, ShortcutChord("Cmd+Enter"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
        try Data(#"[{"command":"composer.toggleDictation","key":"Alt+D"},{"command":"composer.queue","key":null}]"#.utf8)
            .write(to: home.appendingPathComponent("keybindings.json"))
        let custom = CodexShortcuts.load(from: home)
        XCTAssertEqual(custom[.dictate].chord, ShortcutChord("Alt+D"))
        XCTAssertTrue(custom[.dictate].usesToggleDictation)
        XCTAssertFalse(custom[.queue].usesComposerControls)
        XCTAssertNil(custom[.queue].chord)
        try Data(#"[{"command":"composer.toggleDictation","key":null}]"#.utf8)
            .write(to: home.appendingPathComponent("keybindings.json"))
        XCTAssertNil(CodexShortcuts.load(from: home)[.dictate].chord)
    }

    func testDefaultConflictsAndEnterPreferences() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("[desktop]\ncomposerEnterBehavior = \"cmdAlways\"\n".utf8).write(to: home.appendingPathComponent("config.toml"))
        XCTAssertEqual(CodexShortcuts.load(from: home)[.queue].alternateSubmitChord, ShortcutChord("Cmd+Shift+Enter"))
        try Data(#"[{"command":"other","key":"Cmd+Shift+D"},{"command":"composer.submit","key":"Alt+Enter"}]"#.utf8)
            .write(to: home.appendingPathComponent("keybindings.json"))
        let loaded = CodexShortcuts.load(from: home)
        XCTAssertNil(loaded[.dictate].chord)
        XCTAssertTrue(loaded[.queue].usesComposerControls)
        XCTAssertNil(loaded[.queue].alternateSubmitChord)
    }

    func testMigratedQueueCannotSilentlySteer() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("config.toml")
        let migrated = "[desktop] # preferences\nmigratedFollowUpQueueToSteer = true\n"
        try Data(migrated.utf8).write(to: config)
        let loaded = CodexShortcuts.load(from: home)
        XCTAssertNil(loaded[.queue].alternateSubmitChord)
        XCTAssertNotNil(loaded[.queue].alternateUnavailableReason)
        XCTAssertNotNil(loaded[.steer].alternateSubmitChord)
        try Data((migrated + "followUpQueueMode = \"steer\"\n").utf8).write(to: config)
        XCTAssertEqual(CodexShortcuts.load(from: home)[.queue].alternateSubmitChord, ShortcutChord("Cmd+Enter"))
    }

    func testInlineRecordingCleanupRetainsOwnershipWithoutStartAcknowledgement() {
        var lifecycle = InlineDictationLifecycle()
        XCTAssertFalse(lifecycle.claimStop()) // Never stop somebody else’s recorder before dispatch.
        lifecycle.didDispatch()
        XCTAssertTrue(lifecycle.canStop) // Release/disconnect can precede the start acknowledgement.
        XCTAssertTrue(lifecycle.claimStop())
        XCTAssertFalse(lifecycle.claimStop()) // An uncertain AX result must never trigger a second press.
        lifecycle = InlineDictationLifecycle()
        XCTAssertFalse(lifecycle.canStop)
    }

    func testDefaultSubmissionPreservesSteerAndQueueMeaning() {
        XCTAssertEqual(CodexDefaultSubmission.plan(button: "Send", queue: true, alternateAvailable: false), .pressButton)
        XCTAssertEqual(CodexDefaultSubmission.plan(button: "Steer", queue: false, alternateAvailable: false), .pressButton)
        XCTAssertEqual(CodexDefaultSubmission.plan(button: "Queue", queue: true, alternateAvailable: false), .pressButton)
        XCTAssertEqual(CodexDefaultSubmission.plan(button: "Steer", queue: true, alternateAvailable: true), .alternateShortcut)
        XCTAssertEqual(CodexDefaultSubmission.plan(button: "Queue", queue: false, alternateAvailable: true), .alternateShortcut)
        XCTAssertEqual(CodexDefaultSubmission.plan(button: "Steer", queue: true, alternateAvailable: false), .unavailable)
        for label in ["Stop", "Resume", "", "Send feedback"] {
            XCTAssertEqual(CodexDefaultSubmission.plan(button: label, queue: false, alternateAvailable: true), .unavailable)
        }
    }

    @MainActor func testCustomDictationReleasesOriginalPhysicalKeysInReverse() throws {
        let chord = try XCTUnwrap(ShortcutChord("Control+Shift+F5"))
        let events = try chord.holdEvents()
        let releases = events.reversed().map(\.up)
        XCTAssertEqual(releases.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [96, 56, 59])
        XCTAssertEqual(releases.map(\.type), [.keyUp, .flagsChanged, .flagsChanged])
        XCTAssertEqual(releases.map(\.flags), [[.maskControl,.maskShift], .maskControl, []])
        let bare = try XCTUnwrap(ShortcutChord("RightControl")).holdEvents()
        XCTAssertEqual(bare.count, 1)
        XCTAssertEqual(bare.first?.up.getIntegerValueField(.keyboardEventKeycode), 62)
        XCTAssertEqual(bare.first?.up.flags, [])
    }

    @MainActor func testSubmissionTapReleasesEveryModifierAfterLetter() throws {
        for text in ["Control+Shift+Command+F5", "Control+Option+Shift+F5"] {
            let chord = try XCTUnwrap(ShortcutChord(text))
            let events = try chord.tapEvents()
            XCTAssertEqual(events.count, 8)
            XCTAssertEqual(events.prefix(3).map(\.type), Array(repeating: .flagsChanged, count: 3))
            XCTAssertEqual(events[3].type, .keyDown)
            XCTAssertEqual(events[4].type, .keyUp)
            XCTAssertEqual(events.suffix(3).map(\.type), Array(repeating: .flagsChanged, count: 3))
            XCTAssertEqual(events.suffix(4).map { $0.getIntegerValueField(.keyboardEventKeycode) },
                           events.prefix(4).reversed().map { $0.getIntegerValueField(.keyboardEventKeycode) })
            XCTAssertEqual(events.last?.flags, [])
        }
    }
}
#endif
