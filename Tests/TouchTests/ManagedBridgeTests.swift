// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
#if os(macOS)
import XCTest
import TouchCore
@testable import TrackypadyBridge

@MainActor
final class ManagedBridgeTests: XCTestCase {
    func testDisconnectDuringDiscoveryCannotReachKeyPostingOrClearNewOwner() async throws {
        let preparation = DictationPreparation()
        let first = try XCTUnwrap(preparation.begin())
        XCTAssertNil(preparation.begin())
        var posts = 0
        var replacement: UUID?
        do {
            _ = try await preparation.resolve(first, connectionIsCurrent: { true }) {
                await Task.yield()
                preparation.cancel()
                replacement = preparation.begin()
                return "composer"
            }
            posts += 1
        } catch is CancellationError {}
        preparation.finish(first)
        XCTAssertEqual(posts, 0)
        XCTAssertTrue(preparation.isCurrent(try XCTUnwrap(replacement)))
    }

    func testSettingsSeedOnceAndLaterMacEditsWinAcrossRelaunch() throws {
        let suite = "Trackypady-Tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PhonePreferencesStore(defaults: defaults)
        let oldPhone = PhonePreferences(singleFingerSwipesEnabled: false, recordingHapticsEnabled: false, useSystemErrorHaptic: true)
        XCTAssertEqual(store.initialValue(reportedBy: oldPhone), oldPhone)
        store.save(PhonePreferences())
        let reopened = PhonePreferencesStore(defaults: defaults)
        XCTAssertEqual(reopened.initialValue(reportedBy: oldPhone), PhonePreferences())
        XCTAssertEqual(reopened.saved, PhonePreferences())
    }

    func testStopCheckpointRejectsReplacementTruncationNewTurnsAndOversizedDelta() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let prefix = Data("past activity\n".utf8)
        try prefix.write(to: file)
        let checkpoint = try ResponseLogCheckpoint(path: file)
        XCTAssertTrue(try checkpoint.stillCurrent(at: file))
        XCTAssertFalse(try checkpoint.stillCurrent(at: nil))
        XCTAssertFalse(try checkpoint.stillCurrent(at: file.appendingPathExtension("new")))
        for marker in ["method=turn/start ", "turn-start config resolved", "thread_stream_view_activity_changed"] {
            try (prefix + Data(marker.utf8)).write(to: file)
            XCTAssertFalse(try checkpoint.stillCurrent(at: file))
        }
        try (prefix + Data(repeating: 32, count: 262_145)).write(to: file)
        XCTAssertFalse(try checkpoint.stillCurrent(at: file))
        try Data().write(to: file)
        XCTAssertFalse(try checkpoint.stillCurrent(at: file))
    }
}
#endif
