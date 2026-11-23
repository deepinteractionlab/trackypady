// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
#if os(macOS)
import XCTest
@testable import TrackypadyBridge

@MainActor
final class DictationRecoveryTests: XCTestCase {
    func testFailedPhoneOverlayRemainsEligibleOnlyUntilAnotherRecording() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let writer = try FileHandle(forWritingTo: path)
        defer { try? writer.close() }
        func record(_ id: String, _ stage: String, gesture: String = "press-and-hold", window: String = "globalDictation") throws {
            let line = "test dictation.startup attemptId=\(id) rendererWindowAppearance=\(window) stage=\(stage) startGesture=\(gesture) surface=global version=1\n"
            try writer.write(contentsOf: Data(line.utf8))
        }
        try record("old", "renderer_start")
        try record("old", "failed")
        let observation = try XCTUnwrap(GlobalDictationObservation(path: path))
        XCTAssertFalse(observation.ownsFailedOverlay(currentLog: path))
        try record("phone", "renderer_start")
        try record("phone", "stop_requested")
        XCTAssertFalse(observation.ownsFailedOverlay(currentLog: path))
        try record("phone", "failed", window: "main")
        XCTAssertFalse(observation.ownsFailedOverlay(currentLog: path))
        try record("phone", "failed")
        XCTAssertFalse(observation.ownsFailedOverlay(currentLog: path.appendingPathExtension("new")))
        XCTAssertTrue(observation.ownsFailedOverlay(currentLog: path))
        try record("manual", "renderer_start", gesture: "tap")
        try record("manual", "failed", gesture: "tap")
        XCTAssertFalse(observation.ownsFailedOverlay(currentLog: path))
    }

    func testRecoveryRequiresAFinishedCurrentAttemptInTheSameLog() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: log)
        defer { try? FileManager.default.removeItem(at: log) }
        let observer = try XCTUnwrap(GlobalDictationObservation(path: log))
        let writer = try FileHandle(forWritingTo: log)
        defer { try? writer.close() }
        func append(_ id: String, _ stage: String) throws {
            let line = "test dictation.startup attemptId=\(id) stage=\(stage) startGesture=press-and-hold surface=global end=1\n"
            try writer.write(contentsOf: Data(line.utf8))
        }

        XCTAssertFalse(observer.confirmsFinishedAttempt(currentLog: log))
        for stage in ["renderer_start", "recording_started", "stop_requested"] {
            try append("first", stage)
            XCTAssertFalse(observer.confirmsFinishedAttempt(currentLog: log))
        }
        try append("first", "completed")
        XCTAssertTrue(observer.confirmsFinishedAttempt(currentLog: log))
        XCTAssertFalse(observer.confirmsFinishedAttempt(currentLog: nil))
        try append("second", "renderer_start")
        XCTAssertFalse(observer.confirmsFinishedAttempt(currentLog: log))
    }

    func testFreshHoldPressesOnceAndWaitsForDisappearance() async throws {
        var scans = 0, presses = 0
        try await DictationRecoveryBanner.dismissIfPresent(isCurrent: { true }, locate: {
            scans += 1
            return scans <= 2 ? "dismiss" : nil
        }, press: { button in
            XCTAssertEqual(button, "dismiss")
            presses += 1
        })
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(scans, 3)
        try await DictationRecoveryBanner.dismissIfPresent(isCurrent: { true }, locate: { nil as String? },
                                                           press: { _ in XCTFail("Banner already closed") })
    }

    func testUnconfirmedDismissalAndDisconnectInterruptStart() async throws {
        var presses = 0
        do {
            try await DictationRecoveryBanner.dismissIfPresent(timeout: .zero, isCurrent: { true },
                                                               locate: { "dismiss" }, press: { _ in presses += 1 })
            XCTFail("Banner still visible")
        } catch is DictationRecoveryBanner.Failure {}
        XCTAssertEqual(presses, 1)

        var connected = true
        do {
            try await DictationRecoveryBanner.dismissIfPresent(isCurrent: { connected }, locate: {
                connected = false
                return "dismiss"
            }, press: { _ in XCTFail("Phone disconnected") })
            XCTFail("Hold no longer current")
        } catch is CancellationError {}
    }
}
#endif
