// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
#if os(macOS)
import Foundation
import XCTest
@testable import TrackypadyBridge

final class CodexShortcutRefreshTests: XCTestCase {
    @MainActor
    func testRefreshPreservesDraftAndPreventsOverwritingChangedBinding() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let keymap = folder.appendingPathComponent("keybindings.json")
        func save(steer: Any, queue: String) throws {
            try JSONSerialization.data(withJSONObject: [
                ["command": "composer.steer", "key": steer],
                ["command": "composer.queue", "key": queue]
            ]).write(to: keymap, options: .atomic)
        }

        try save(steer: "Ctrl+Alt+S", queue: "Ctrl+Alt+Q")
        let suite = "Trackypady-Tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bridge = BridgeModel(shortcutHome: folder, shortcutDefaults: defaults, codexLaunchDate: { nil })
        bridge.refreshSavedShortcuts()
        XCTAssertTrue(bridge.isShortcutConfigured(.steer))
        XCTAssertNil(bridge.shortcutAttentionDetail(.steer))
        XCTAssertNil(bridge.lastShortcutPush)
        bridge.editShortcut(.steer, to: "Ctrl+Alt+K", basedOn: try XCTUnwrap(bridge.shortcutEditBase(for: .steer)))

        try save(steer: "Ctrl+Alt+S", queue: "Ctrl+Alt+J")
        bridge.refreshSavedShortcuts()
        XCTAssertEqual(bridge.shortcutDrafts[.queue], "Ctrl+Alt+J")
        XCTAssertEqual(bridge.shortcutDrafts[.steer], "Ctrl+Alt+K")
        XCTAssertFalse(bridge.shortcutEditsConflict)

        try save(steer: NSNull(), queue: "Ctrl+Alt+J")
        bridge.refreshSavedShortcuts()
        XCTAssertFalse(bridge.isShortcutConfigured(.steer))
        XCTAssertEqual(bridge.shortcutAttentionDetail(.steer), "Disabled in Codex.")
        XCTAssertNil(bridge.shortcutAttentionDetail(.queue))
        XCTAssertTrue(bridge.shortcutEditsConflict)
        XCTAssertEqual(bridge.shortcutAttentionDetail(.steer, includeRepairGuidance: true),
                       "This shortcut changed in Codex. Click Discard changes, edit the shortcut again, then click Push changes to Codex.")
        XCTAssertEqual(bridge.shortcutDrafts[.steer], "Ctrl+Alt+K")
        let externallySaved = try Data(contentsOf: keymap)
        bridge.pushCodexShortcuts()
        XCTAssertEqual(try Data(contentsOf: keymap), externallySaved)
        XCTAssertNil(bridge.lastShortcutPush)

        bridge.discardShortcutEdits()
        XCTAssertEqual(bridge.shortcutAttentionDetail(.steer, includeRepairGuidance: true),
                       "Disabled in Codex. Click Change to assign a shortcut, then click Push changes to Codex.")
        XCTAssertFalse(bridge.hasShortcutEdits)
        XCTAssertEqual(bridge.shortcutDrafts[.steer], "")
        XCTAssertEqual(try Data(contentsOf: keymap), externallySaved)

        bridge.editShortcut(.steer, to: "Ctrl+Alt+K", basedOn: try XCTUnwrap(bridge.shortcutEditBase(for: .steer)))
        bridge.pushCodexShortcuts()
        XCTAssertTrue(bridge.isShortcutConfigured(.steer))
        XCTAssertFalse(bridge.hasShortcutEdits)
        XCTAssertEqual(bridge.shortcutDrafts[.steer], "Ctrl+Alt+K")
        let pushedAt = try XCTUnwrap(bridge.lastShortcutPush)
        bridge.refreshSavedShortcuts(force: true)
        XCTAssertEqual(bridge.lastShortcutPush, pushedAt)
        let reopened = BridgeModel(shortcutHome: folder, shortcutDefaults: defaults)
        XCTAssertEqual(reopened.lastShortcutPush, pushedAt)
    }

    @MainActor
    func testPushBlocksOnlyChangedShortcutsUntilNewCodexLaunchAndReadableBindings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "Trackypady-Tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keymap = folder.appendingPathComponent("keybindings.json")
        try Data("""
        [{"command":"composer.steer","key":"Ctrl+Alt+S"},
         {"command":"composer.queue","key":"Ctrl+Alt+Q"}]
        """.utf8).write(to: keymap)

        var launch: Date? = .distantPast
        let bridge = BridgeModel(shortcutHome: folder, shortcutDefaults: defaults, codexLaunchDate: { launch })
        bridge.refreshSavedShortcuts()
        bridge.editShortcut(.steer, to: "Ctrl+Alt+K", basedOn: try XCTUnwrap(bridge.shortcutEditBase(for: .steer)))
        bridge.pushCodexShortcuts()
        XCTAssertEqual(bridge.shortcutAttentionDetail(.steer), "Codex restart required")
        XCTAssertNil(bridge.shortcutAttentionDetail(.queue))
        XCTAssertTrue(bridge.shortcutForDispatch(.steer).requiresRestart)
        XCTAssertNil(bridge.shortcutForDispatch(.steer).chord)
        XCTAssertNotNil(bridge.shortcutForDispatch(.queue).chord)

        let reopened = BridgeModel(shortcutHome: folder, shortcutDefaults: defaults, codexLaunchDate: { launch })
        XCTAssertTrue(reopened.shortcutForDispatch(.steer).requiresRestart)
        launch = nil
        XCTAssertTrue(reopened.shortcutForDispatch(.steer).requiresRestart, "Quitting alone cannot clear the reminder")

        let saved = try Data(contentsOf: keymap)
        try Data("invalid".utf8).write(to: keymap, options: .atomic)
        launch = .distantFuture
        XCTAssertTrue(reopened.shortcutForDispatch(.steer).requiresRestart)

        try saved.write(to: keymap, options: .atomic)
        let binding = reopened.shortcutForDispatch(.steer)
        XCTAssertFalse(binding.requiresRestart)
        XCTAssertNil(reopened.shortcutAttentionDetail(.steer))
        XCTAssertEqual(binding.display, "Ctrl+Alt+K")
        XCTAssertNotNil(binding.chord)
        let afterRestart = BridgeModel(shortcutHome: folder, shortcutDefaults: defaults, codexLaunchDate: { launch })
        XCTAssertFalse(afterRestart.shortcutNeedsRestart(.steer))
    }
}
#endif
