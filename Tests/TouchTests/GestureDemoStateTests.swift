// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import TouchCore

final class GestureDemoStateTests: XCTestCase {
    private func draft() -> GestureDemoState {
        var state = GestureDemoState()
        XCTAssertTrue(state.bringToFront())
        XCTAssertTrue(state.beginRecording())
        XCTAssertTrue(state.releaseRecording(cancelled: false))
        XCTAssertEqual(state.phase, .transcribing)
        XCTAssertFalse(state.send())
        XCTAssertFalse(state.swipeDown())
        state.finishTranscribing()
        return state
    }
    func testReadyAndSelectedDraftsCanBothBeSent() {
        for select in [false, true] {
            var state = draft()
            if select { XCTAssertTrue(state.swipeDown()); XCTAssertEqual(state.phase, .draftSelected) }
            XCTAssertTrue(state.send())
            XCTAssertEqual(state.step, 3)
            XCTAssertFalse(state.send(), "One send per gesture")
            state.finishAction()
            XCTAssertEqual(state.phase, .bringToFront)
            XCTAssertEqual(state.completion, .sent)
            XCTAssertTrue(state.bringToFront())
            XCTAssertTrue(state.beginRecording())
            XCTAssertNil(state.completion)
        }
    }
    func testDiscardSelectsFirstThenDeletesAndResets() {
        var state = draft()
        XCTAssertTrue(state.swipeDown())
        XCTAssertEqual(state.phase, .draftSelected)
        XCTAssertTrue(state.hasDraft)
        XCTAssertTrue(state.swipeDown())
        XCTAssertEqual(state.phase, .discarding)
        XCTAssertFalse(state.swipeDown())
        state.finishAction()
        XCTAssertEqual(state.phase, .bringToFront)
        XCTAssertEqual(state.completion, .discarded)
    }
    func testThinkingFollowsSendAnimationAndReturnsToIdle() {
        var state = draft()
        XCTAssertTrue(state.send())
        state.finishSendingAnimation()
        XCTAssertEqual(state.phase, .thinking)
        XCTAssertFalse(state.movePage(by: -1))
        XCTAssertFalse(state.beginRecording())
        state.finishAction()
        XCTAssertEqual(state.phase, .bringToFront)
        XCTAssertEqual(state.completion, .sent)
        state.finishSendingAnimation()
        XCTAssertEqual(state.phase, .bringToFront)
    }

    func testCarouselMovesComposerBothWaysAndKeepsVerticalActionsAvailable() {
        var state = GestureDemoState()
        XCTAssertFalse(state.movePage(by: -1))
        for phase in [GestureDemoState.Phase.idle, .draftReady, .draftSelected] {
            XCTAssertTrue(state.movePage(by: 1))
            XCTAssertEqual(state.phase, phase)
        }
        XCTAssertFalse(state.movePage(by: 1))
        for phase in [GestureDemoState.Phase.draftReady, .idle, .bringToFront] {
            XCTAssertTrue(state.movePage(by: -1))
            XCTAssertEqual(state.phase, phase)
        }
        for _ in 0..<3 { XCTAssertTrue(state.movePage(by: 1)) }
        XCTAssertTrue(state.send())
        XCTAssertFalse(state.movePage(by: -1), "Do not interrupt a committed send")
        state.finishAction()
        for _ in 0..<2 { XCTAssertTrue(state.movePage(by: 1)) }
        XCTAssertTrue(state.swipeDown())
        XCTAssertTrue(state.swipeDown())
        XCTAssertEqual(state.phase, .discarding)
    }
    func testBringToFrontIsRequiredBeforeRecordingAndAcknowledgedOnlyOnce() {
        var state = GestureDemoState()
        XCTAssertEqual(state.phase, .bringToFront)
        XCTAssertFalse(state.beginRecording())
        XCTAssertTrue(state.bringToFront())
        XCTAssertFalse(state.bringToFront())
        XCTAssertEqual(state.step, 1)
        XCTAssertTrue(state.beginRecording())
    }

    func testCombinedWakeAndHoldStartsRecordingWithoutWaitingForTapCompletion() {
        var state = GestureDemoState()
        XCTAssertTrue(state.beginRecording(bringForwardIfNeeded: true))
        XCTAssertEqual(state.phase, .recording)
        XCTAssertFalse(state.beginRecording(bringForwardIfNeeded: true))
        XCTAssertTrue(state.releaseRecording(cancelled: false))
        state.finishTranscribing()
        XCTAssertEqual(state.phase, .draftReady)
        XCTAssertFalse(state.beginRecording(bringForwardIfNeeded: true))
        state.reset()
        XCTAssertTrue(state.beginRecording(bringForwardIfNeeded: true))
        XCTAssertFalse(state.releaseRecording(cancelled: true))
        XCTAssertEqual(state.phase, .idle)
    }

    func testCancellationAndStaleCompletionsNeverCreateADraft() {
        var state = GestureDemoState()
        XCTAssertFalse(state.send())
        XCTAssertFalse(state.swipeDown())
        XCTAssertTrue(state.bringToFront())
        XCTAssertTrue(state.beginRecording())
        XCTAssertFalse(state.releaseRecording(cancelled: true))
        state.finishTranscribing()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(state.beginRecording())
        XCTAssertTrue(state.releaseRecording(cancelled: false))
        state.reset()
        state.finishTranscribing()
        state.finishAction()
        XCTAssertEqual(state, GestureDemoState())
    }
}
