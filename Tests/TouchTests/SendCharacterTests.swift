// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import CharacterKit
import TouchCore

final class SendCharacterTests: XCTestCase {
    func testQueueStepsStartWithTheHoldCue() {
        let settings = CharacterSettings()
        let preview = CharacterSendPreview.pendingQueue()
        let studio = CharacterSendPreview(.queue)
        for elapsed in [0, 0.06, 0.18, 0.25, 0.31, 0.50, 0.62, 1.86] {
            let live = preview.pose(settings: settings, idleTime: 2 + elapsed, elapsed: elapsed)
            let studioTime = elapsed + QueueGesture.intentDelay
            let expected = studio.pose(settings: settings, idleTime: 2 + studioTime, elapsed: studioTime)
            XCTAssertEqual(live.gazeY, expected.gazeY, accuracy: 0.0001)
            XCTAssertEqual(live.pupilHeight, expected.pupilHeight, accuracy: 0.0001)
            XCTAssertEqual(live.showsSendArch, expected.showsSendArch)
        }
    }

    func testDelayedQueueStaysUpUntilCommitThenReturnsToIdle() {
        let settings = CharacterSettings()
        let start = Date()
        var preview = CharacterSendPreview.pendingQueue(at: start)
        func pose(_ elapsed: Double) -> CharacterPose {
            preview.pose(settings: settings, idleTime: 2 + elapsed, elapsed: elapsed)
        }
        let apex = pose(QueueGesture.holdDuration)
        XCTAssertTrue(preview.isHoldingQueue)
        XCTAssertTrue(pose(6).showsSendArch)
        XCTAssertEqual(pose(6).gazeY, apex.gazeY, accuracy: 0.0001)
        preview.commitQueue(at: start.addingTimeInterval(6))
        XCTAssertFalse(preview.isHoldingQueue)
        XCTAssertGreaterThan(pose(6.25).gazeY, apex.gazeY)
        XCTAssertFalse(pose(6.25).showsSendArch)
        let idle = CharacterMotion.sample(state: .idle, settings: settings, time: 9)
        XCTAssertEqual(pose(7).gazeX, idle.gazeX)
        XCTAssertEqual(pose(7).gazeY, idle.gazeY)
    }
}
