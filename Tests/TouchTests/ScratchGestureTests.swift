// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
import TouchCore

final class ScratchGestureTests: XCTestCase {
    func testThreeTiltedStrokesEitherDirectionFireOnceWhileHeld() {
        for sign in [-1.0, 1.0] {
            var gesture = ScratchGesture(started: 10)
            var fired: [Int] = []
            for i in 0..<10 {
                let x = i.isMultiple(of: 2) ? sign * 32 : 0
                if gesture.move(x: x, y: x * 0.5, touches: 3, now: 10 + Double(i + 1) * 0.2) { fired.append(i) }
            }
            XCTAssertEqual(fired, [2])
            XCTAssertEqual(gesture.recognizedDirection, sign < 0 ? .left : .right)
            XCTAssertEqual(gesture.phase, .consumed)
        }
    }
    func testTwoOrMoreContactsCanChangeWithoutRestartingTheScratch() {
        for counts in [[2,2,2,2,2,2], [3,2,3,4,5,2], [4,4,4,4,4,4], [1,1,1,1,1,1]] {
            var gesture = ScratchGesture(started: 0)
            for (i,count) in counts.enumerated() {
                let fired = gesture.move(x: i.isMultiple(of: 2) ? -24 : 0, y: 2, touches: count, now: Double(i + 1)*0.2)
                XCTAssertEqual(fired, i == 2 && count >= 2)
            }
        }
    }

    func testThirdStrokeMustFinishInsideInclusiveWindow() {
        let start = 12345.0
        for (duration, accepted) in [(0.199, false), (0.20, true), (0.30, true), (0.72, true), (0.90, true), (0.901, false)] {
            var gesture = ScratchGesture(started: start)
            for i in 0..<2 {
                XCTAssertFalse(gesture.move(x: i.isMultiple(of: 2) ? 25 : 0, y: 0, touches: 2, now: start + Double(i) * 0.07))
            }
            XCTAssertEqual(gesture.move(x: 25, y: 0, touches: 2, now: start + duration), accepted)
            XCTAssertEqual(gesture.phase, accepted ? .consumed : .scratching)
        }
    }

    func testContinuousScratchCanRecoverFromFastOrSlowOpeningStrokes() {
        for openingStrokeTime in [0.05, 0.55] {
            var gesture = ScratchGesture(started: 0)
            var time = 0.0
            var firedAt: [Int] = []
            for stroke in 1...22 {
                time += stroke <= 3 ? openingStrokeTime : 0.22
                if gesture.move(x: stroke.isMultiple(of: 2) ? 0 : 25, y: 0, touches: 2, now: time) {
                    firedAt.append(stroke)
                }
            }
            XCTAssertEqual(firedAt.count, 1)
            XCTAssertTrue((4...6).contains(firedAt.first ?? 0))
            XCTAssertEqual(gesture.recognizedDirection, firedAt.first?.isMultiple(of: 2) == true ? .left : .right)
        }
    }

    func testSustainedOutOfRangeCadenceNeverFires() {
        for strokeTime in [0.05, 0.36] {
            var gesture = ScratchGesture(started: 0)
            for stroke in 1...30 {
                XCTAssertFalse(gesture.move(x: stroke.isMultiple(of: 2) ? 0 : 28, y: 0,
                                            touches: 3, now: Double(stroke) * strokeTime))
            }
            XCTAssertEqual(gesture.phase, .scratching)
        }
    }

    func testFasterDefaultAndAdjustedWindowReachRecognizerViaStatus() throws {
        XCTAssertEqual(ScratchTiming.fast, ScratchTiming(minimumMS: 200, maximumMS: 900))
        // The installed phone can start with the former default. A Mac status
        // receipt must replace it and accept a 0.30-second scratch.
        let status = WakeReceipt(id: UUID(), outcome: .status, message: "", scratchTiming: .fast)
        let synced = try XCTUnwrap(JSONDecoder().decode(WakeReceipt.self, from: JSONEncoder().encode(status)).scratchTiming)
        for timing in [ScratchTiming(minimumMS: 450, maximumMS: 1000), synced] {
            var gesture = ScratchGesture(started: 0, timing: timing)
            for stroke in 1...3 {
                let matched = gesture.move(x: stroke.isMultiple(of: 2) ? 0 : 24, y: 0, touches: 2, now: Double(stroke) * 0.1)
                XCTAssertEqual(matched, stroke == 3 && timing == synced)
            }
        }
        let custom = ScratchTiming(minimumMS: 150, maximumMS: 400)
        let reply = WakeReceipt(id: UUID(), outcome: .status, message: "", scratchTiming: custom)
        let received = try JSONDecoder().decode(WakeReceipt.self, from: JSONEncoder().encode(reply))
        let applied = try XCTUnwrap(received.scratchTiming)
        for timing in [ScratchTiming.fast, applied] {
            var gesture = ScratchGesture(started: 0, timing: timing)
            for stroke in 1...3 {
                let matched = gesture.move(x: stroke.isMultiple(of: 2) ? 0 : 24, y: 0, touches: 2, now: Double(stroke) * 0.16)
                XCTAssertEqual(matched, stroke == 3 && timing == .fast)
            }
        }
        let request = WakeRequest(action: .getStatus, appliedScratchTiming: applied, lastScratchTrial: "0.48 s")
        XCTAssertEqual(try JSONDecoder().decode(WakeRequest.self, from: JSONEncoder().encode(request)), request)
    }

    func testJitterAndOvershootDoNotDoubleCount() {
        var gesture = ScratchGesture(started: 0)
        for x in [12, 25, 48, 46, 49, 44, 35, 31] {
            XCTAssertFalse(gesture.move(x: Double(x), y: 2, touches: 3, now: 0.3))
        }
        XCTAssertEqual(gesture.strokes, 1)
        XCTAssertFalse(gesture.move(x: 24, y: 1, touches: 3, now: 0.5))
        XCTAssertEqual(gesture.strokes, 2)
    }
    func testUnevenLandingAndBriefTiltRecoverWithinTheSameScratch() {
        var gesture = ScratchGesture(started: 0)
        XCTAssertFalse(gesture.move(x: 11, y: 12, touches: 3, now: 0.05))
        XCTAssertEqual(gesture.phase, .undecided)
        XCTAssertFalse(gesture.move(x: 21, y: 7, touches: 3, now: 0.2))
        XCTAssertFalse(gesture.move(x: 1, y: 24, touches: 3, now: 0.3))
        XCTAssertEqual(gesture.strokes, 1)
        XCTAssertFalse(gesture.move(x: 1, y: 3, touches: 3, now: 0.35))
        XCTAssertTrue(gesture.move(x: 21, y: 3, touches: 3, now: 0.5))
    }
    func testVerticalSwipesRemainAvailableAndIncompleteScratchesStayConsumed() {
        var vertical = ScratchGesture(started: 0)
        XCTAssertFalse(vertical.move(x: 5, y: 22, touches: 3, now: 0))
        XCTAssertEqual(vertical.phase, .vertical)
        for (touches, time) in [(1, 0.5), (3, 2.01)] {
            var gesture = ScratchGesture(started: 0)
            XCTAssertFalse(gesture.move(x: 28, y: 5, touches: 3, now: 0.1))
            XCTAssertFalse(gesture.move(x: 0, y: 0, touches: touches, now: time))
            XCTAssertEqual(gesture.phase, touches < 2 ? .consumed : .scratching)
        }
    }
}
