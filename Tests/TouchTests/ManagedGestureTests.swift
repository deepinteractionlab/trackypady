// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
import TouchCore

final class ManagedGestureTests: XCTestCase {
    func testLatePrepareCannotAttachASecondScratchToTheFirstStop() throws {
        var session = ScratchStopSession()
        let first = UUID(), second = UUID()
        XCTAssertEqual(session.begin(first)?.action, .prepareResponseStop)
        XCTAssertNil(session.recognize(first, contacts: 3, direction: .left))
        XCTAssertFalse(session.release(first))
        session.finishPan(first)
        XCTAssertNil(session.begin(second))
        XCTAssertNil(session.recognize(second, contacts: 3, direction: .right))
        session.finishPan(second)
        let stop = try XCTUnwrap(session.prepared(first, successful: true))
        XCTAssertEqual(stop.scratchID, first)
        let receipt = WakeReceipt(id: stop.id, outcome: .stopPressed, message: "", dictateAfterStop: true)
        XCTAssertNil(session.confirmedDirection(for: second, receipt: receipt))
        XCTAssertEqual(session.confirmedDirection(for: first, receipt: receipt), .left)
        XCTAssertFalse(session.acknowledge(first, receipt: receipt))
        XCTAssertNil(session.prepared(first, successful: true))
        XCTAssertNotNil(session.begin(second))
    }

    func testPreparedScratchStartsOnlyItsOwnHeldDictationOnce() throws {
        var session = ScratchStopSession()
        let id = UUID()
        _ = session.begin(id)
        XCTAssertNil(session.prepared(id, successful: true))
        let stop = try XCTUnwrap(session.recognize(id, contacts: 3, direction: .right))
        XCTAssertNil(session.recognize(id, contacts: 3))
        let receipt = WakeReceipt(id: stop.id, outcome: .stopPressed, message: "", dictateAfterStop: true)
        let missed = WakeReceipt(id: stop.id, outcome: .noActiveResponse, message: "")
        XCTAssertNil(session.confirmedDirection(for: id, receipt: missed))
        XCTAssertEqual(session.confirmedDirection(for: id, receipt: receipt), .right)
        XCTAssertFalse(session.release(UUID()))
        XCTAssertTrue(session.acknowledge(id, receipt: receipt))
        XCTAssertFalse(session.acknowledge(id, receipt: receipt))
        XCTAssertFalse(session.beginHeldDictation(UUID()))
        XCTAssertTrue(session.beginHeldDictation(id))
        XCTAssertFalse(session.beginHeldDictation(id))
        XCTAssertTrue(session.release(id))
        XCTAssertFalse(session.release(id))
    }

    func testReleaseDuringPostStopHoldLeavesNextGestureFree() throws {
        var session = ScratchStopSession()
        func acknowledgeStop(_ id: UUID) throws {
            XCTAssertNotNil(session.begin(id))
            _ = session.prepared(id, successful: true)
            let stop = try XCTUnwrap(session.recognize(id, contacts: 3))
            let receipt = WakeReceipt(id: stop.id, outcome: .stopPressed, message: "", dictateAfterStop: true)
            XCTAssertTrue(session.acknowledge(id, receipt: receipt))
        }
        let first = UUID(), second = UUID()
        try acknowledgeStop(first)
        XCTAssertFalse(session.release(first))
        try acknowledgeStop(second)
        XCTAssertFalse(session.beginHeldDictation(first))
        XCTAssertTrue(session.beginHeldDictation(second))
        XCTAssertTrue(session.release(second))
    }

    func testCancelledOrRejectedPreparationCanBeReplaced() {
        var session = ScratchStopSession()
        let first = UUID(), second = UUID()
        _ = session.begin(first)
        session.finishPan(first)
        _ = session.begin(second)
        XCTAssertNil(session.prepared(first, successful: true))
        XCTAssertNil(session.prepared(second, successful: false))
        XCTAssertNotNil(session.begin(UUID()))
    }

    func testLateSecondFingerStartsScratchAtItsOwnOrigin() {
        var pan = PadInteraction(contacts: 1, allowSingleFinger: false, timing: .fast, discardAtTouchDown: nil, now: 0)
        _ = pan.move(to: CGPoint(x: 100, y: 0), contacts: 1, now: 0.1)
        XCTAssertTrue(pan.move(to: CGPoint(x: 100, y: 0), contacts: 2, now: 0.2).isEmpty)
        guard case .beginScratch(let id) = pan.move(to: CGPoint(x: 130, y: 0), contacts: 2, now: 0.4).first else {
            return XCTFail("Expected a scratch")
        }
        XCTAssertFalse(pan.claimHold(at: .zero))
        _ = pan.move(to: CGPoint(x: 100, y: 0), contacts: 2, now: 0.6)
        guard case .completeScratch(id, contacts: 2, direction: .right) = pan.move(to: CGPoint(x: 130, y: 0), contacts: 2, now: 0.8).first else {
            return XCTFail("Expected the same scratch to complete")
        }
        XCTAssertFalse(pan.needsQueueTimer)
    }

    func testSingleFingerModeAllowsStopWithoutChangingSwipeArbitration() {
        for enabled in [true, false] {
            var scratch = PadInteraction(contacts: 1, allowSingleFinger: enabled, timing: .fast,
                                         discardAtTouchDown: nil, now: 0)
            let left = CGPoint(x: -30, y: 0)
            let right = CGPoint(x: 15, y: 0)
            let began = scratch.move(to: left, contacts: 1, now: 0.1)
            _ = scratch.move(to: right, contacts: 1, now: 0.2)
            let completed = scratch.move(to: left, contacts: 1, now: 0.3)
            if enabled {
                guard case .beginScratch(let id) = began.first,
                      case .completeScratch(id, contacts: 1, direction: .left) = completed.first else {
                    return XCTFail("Expected a one-finger scratch")
                }
                XCTAssertTrue(scratch.move(to: right, contacts: 1, now: 0.4).isEmpty)
            } else {
                XCTAssertTrue(began.isEmpty)
                XCTAssertTrue(completed.isEmpty)
            }
        }

        var swipe = PadInteraction(contacts: 1, allowSingleFinger: true, timing: .fast,
                                   discardAtTouchDown: nil, now: 0)
        let up = CGPoint(x: 0, y: -40)
        _ = swipe.move(to: up, contacts: 1, now: 0.1)
        let released = swipe.finish(at: up, now: 0.2, cancelled: false)
        XCTAssertTrue(released.contains { if case .steer = $0 { true } else { false } })
    }

    func testScratchCancelsOnlyWhenContactsFallBelowTheModeMinimum() {
        for enabled in [true, false] {
            var pan = PadInteraction(contacts: 2, allowSingleFinger: enabled, timing: .fast,
                                     discardAtTouchDown: nil, now: 0)
            let left = CGPoint(x: -30, y: 0)
            let right = CGPoint(x: 15, y: 0)
            guard case .beginScratch(let id) = pan.move(to: left, contacts: 2, now: 0.1).first else {
                return XCTFail("Expected a two-finger scratch to begin in either mode")
            }
            _ = pan.contactsRemaining(1)
            _ = pan.move(to: right, contacts: 1, now: 0.2)
            let finished = pan.move(to: left, contacts: 1, now: 0.3)
            if enabled {
                guard case .completeScratch(id, contacts: 1, direction: .left) = finished.first else {
                    return XCTFail("Expected the scratch to continue with one finger")
                }
            } else {
                XCTAssertTrue(finished.isEmpty)
                XCTAssertTrue(pan.move(to: right, contacts: 2, now: 0.4).isEmpty)
            }
        }
    }

    func testQueueOwnsDelayedReleaseAndNeverFallsThroughToSteer() {
        var pan = PadInteraction(contacts: 3, allowSingleFinger: false, timing: .fast, discardAtTouchDown: nil, now: 0)
        let up = CGPoint(x: 0, y: -35)
        _ = pan.move(to: up, contacts: 3, now: 0.1)
        XCTAssertTrue(pan.needsQueueTimer)
        XCTAssertFalse(pan.claimHold(at: .zero))
        XCTAssertTrue(pan.tick(at: up, contacts: 0, now: 4).isEmpty)
        let commit = pan.tick(at: up, contacts: 1, now: 4)
        XCTAssertTrue(commit.contains { if case .queue = $0 { true } else { false } })
        XCTAssertFalse(pan.needsQueueTimer)
        let released = pan.finish(at: up, now: 4.1, cancelled: false)
        XCTAssertEqual(released.count, 1)
        guard case .queueReleased = released.first else { return XCTFail("Expected cleanup only") }
    }

    func testSettlingPanCanBecomeHoldAndRepeatDiscardStaysScoped() {
        var pan = PadInteraction(contacts: 3, allowSingleFinger: true, timing: .fast, discardAtTouchDown: nil, now: 0)
        XCTAssertTrue(pan.claimHold(at: CGPoint(x: 3, y: 4)))
        let down = CGPoint(x: 0, y: 50)
        XCTAssertTrue(pan.move(to: down, contacts: 3, now: 0.45).isEmpty)
        XCTAssertTrue(pan.finish(at: down, now: 0.6, cancelled: false).isEmpty)
        let selection = UUID()
        var repeatPan = PadInteraction(contacts: 1, allowSingleFinger: true, timing: .fast,
                                       discardAtTouchDown: selection, now: 0)
        XCTAssertFalse(repeatPan.claimHold(at: .zero))
        guard case .repeatDiscard(selection) = repeatPan.finish(at: down, now: 0.3, cancelled: false).first else {
            return XCTFail("Expected the original selection")
        }
    }

    func testExistingPreferencesKeepTheirFlagsAndDefaultHoldDuration() throws {
        let legacy = Data(#"{"singleFingerSwipesEnabled":false,"recordingHapticsEnabled":false,"useSystemErrorHaptic":true}"#.utf8)
        let prefs = try JSONDecoder().decode(PhonePreferences.self, from: legacy)
        XCTAssertEqual(prefs.dictationHoldDuration, 0.45)
        XCTAssertFalse(prefs.singleFingerSwipesEnabled)
        XCTAssertFalse(prefs.hapticsDisabled)
        XCTAssertFalse(prefs.recordingHapticsEnabled)
        XCTAssertTrue(prefs.useSystemErrorHaptic)
    }

    func testDictationHoldSpeedStopsAndMigration() {
        let stops = [0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60]
        XCTAssertEqual(PhonePreferences.dictationHoldDurations, stops)
        for (index, duration) in stops.enumerated() {
            XCTAssertEqual(PhonePreferences.holdSpeedIndex(for: duration), index)
            XCTAssertEqual(PhonePreferences(dictationHoldDuration: duration).dictationHoldDuration, duration)
        }
        XCTAssertEqual(PhonePreferences(dictationHoldDuration: 0.25).dictationHoldDuration, 0.30)
        XCTAssertEqual(PhonePreferences(dictationHoldDuration: 0.32).dictationHoldDuration, 0.30)
        XCTAssertEqual(PhonePreferences(dictationHoldDuration: 0.33).dictationHoldDuration, 0.35)
    }

    func testPreferencesRoundTripAndLegacyReceiptsDecode() throws {
        let prefs = PhonePreferences(singleFingerSwipesEnabled: false, recordingHapticsEnabled: false, useSystemErrorHaptic: true, dictationHoldDuration: 0.35)
        let request = WakeRequest(action: .getStatus, appliedPhonePreferences: prefs)
        let receipt = WakeReceipt(id: request.id, outcome: .status, message: "", phonePreferences: prefs)
        XCTAssertEqual(try JSONDecoder().decode(WakeRequest.self, from: JSONEncoder().encode(request)).appliedPhonePreferences, prefs)
        XCTAssertEqual(try JSONDecoder().decode(WakeReceipt.self, from: JSONEncoder().encode(receipt)).phonePreferences, prefs)
        let legacy = try JSONSerialization.data(withJSONObject: ["version": 1, "id": request.id.uuidString,
                                                                 "outcome": "failed", "message": "Queue command sent · unconfirmed"])
        let decoded = try JSONDecoder().decode(WakeReceipt.self, from: legacy)
        XCTAssertNil(decoded.phonePreferences)
        XCTAssertEqual(decoded.submissionResult(for: .sendQueue), .legacyUnconfirmed)
        XCTAssertEqual(decoded.submissionResult(for: .sendSteering), .failed)
    }
}
