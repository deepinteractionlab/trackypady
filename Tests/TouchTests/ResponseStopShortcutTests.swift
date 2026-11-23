// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
#if os(macOS)
import XCTest
@testable import TrackypadyBridge

@MainActor
final class ResponseStopShortcutTests: XCTestCase {
    func testPreparationBringsCodexForwardBeforeCapturingTarget() async throws {
        let preparation = ResponseStopPreparation()
        var foreground = false
        var order: [String] = []
        let target = try await preparation.capture(isCurrent: { true }, activate: {
            order.append("activate")
            await Task.yield()
            foreground = true
        }, target: {
            XCTAssertTrue(foreground)
            order.append("capture")
            return "Codex window"
        })
        XCTAssertEqual(target, "Codex window")
        XCTAssertEqual(order, ["activate", "capture"])
    }

    func testFailedActivationOrInterruptedPreparationCannotCaptureTarget() async throws {
        enum Failure: Error { case activation }
        for mode in 0..<4 {
            let preparation = ResponseStopPreparation()
            var current = mode != 0
            var activated = false
            var captured = false
            do {
                _ = try await preparation.capture(isCurrent: { current }, activate: {
                    activated = true
                    if mode == 1 { throw Failure.activation }
                    if mode == 2 { current = false }
                    if mode == 3 { preparation.cancel() }
                }, target: { captured = true })
                XCTFail("Interrupted preparation must fail")
            } catch {}
            XCTAssertEqual(activated, mode != 0)
            XCTAssertFalse(captured)
        }
    }

    func testSupersededPreparationCannotOverwriteNewTarget() async throws {
        let preparation = ResponseStopPreparation()
        var captures: [String] = []
        do {
            _ = try await preparation.capture(isCurrent: { true }, activate: {
                _ = try await preparation.capture(isCurrent: { true }, activate: {}, target: {
                    captures.append("new")
                })
            }, target: { captures.append("old") })
            XCTFail("Superseded preparation must fail")
        } catch is CancellationError {}
        XCTAssertEqual(captures, ["new"])
    }

    func testStableTargetGetsExactlyTwoPressesWithConfirmationGap() async throws {
        let shortcut = ResponseStopShortcut()
        var events: [String] = []
        let sent = try await shortcut.send(isCurrent: { events.append("validate"); return true },
            pressEscape: { events.append("escape") }, waitForConfirmation: { events.append("wait") })
        XCTAssertTrue(sent)
        XCTAssertEqual(events, ["validate", "escape", "wait", "validate", "escape"])
    }

    func testChangedTargetOrConnectionNeverGetsConfirmationKey() async throws {
        for changesBeforeFirstPress in [true, false] {
            let shortcut = ResponseStopShortcut()
            var current = !changesBeforeFirstPress
            var presses = 0
            let sent = try await shortcut.send(isCurrent: { current }, pressEscape: { presses += 1 },
                waitForConfirmation: { current = false })
            XCTAssertFalse(sent)
            XCTAssertEqual(presses, changesBeforeFirstPress ? 0 : 1)
        }
    }

    func testConcurrentStopCannotInterleaveAndCancelledSequenceDoesNotRetry() async throws {
        let shortcut = ResponseStopShortcut()
        var presses = 0
        do {
            _ = try await shortcut.send(isCurrent: { true }, pressEscape: { presses += 1 }, waitForConfirmation: {
                let duplicate = try await shortcut.send(isCurrent: { true }, pressEscape: { presses += 1 }, waitForConfirmation: {})
                XCTAssertFalse(duplicate)
                throw CancellationError()
            })
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(presses, 1)
        let next = try await shortcut.send(isCurrent: { true }, pressEscape: { presses += 1 }, waitForConfirmation: {})
        XCTAssertTrue(next)
        XCTAssertEqual(presses, 3)
    }

    func testTurnChangeInLogBetweenEscapePressesCancelsSecondPress() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        let checkpoint = try ResponseLogCheckpoint(path: file)
        var presses = 0
        let sent = try await ResponseStopShortcut().send(isCurrent: { try checkpoint.stillCurrent(at: file) },
            pressEscape: { presses += 1 }, waitForConfirmation: {
                try Data("thread_stream_view_activity_changed\n".utf8).write(to: file)
            })
        XCTAssertFalse(sent)
        XCTAssertEqual(presses, 1)
    }
}
#endif
