// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
import TouchCore

final class QueueTests: XCTestCase {
    func testQuickUpStillSteersAndNeverQueues() {
        var gesture=QueueGesture(startedAt:0)
        XCTAssertFalse(gesture.update(x:0,y:-80,now:0.1))
        XCTAssertFalse(gesture.pending)
        XCTAssertTrue(gesture.release(x:0,y:-80,now:0.2))
        XCTAssertFalse(gesture.update(x:0,y:-80,now:1))
    }
    func testQueueHoldCommitsExactlyOnceAndCannotFallThrough() {
        var gesture=QueueGesture(startedAt:0)
        XCTAssertFalse(gesture.update(x:0,y:-80,now:0.1))
        XCTAssertFalse(gesture.update(x:0,y:-80,now:0.31))
        XCTAssertTrue(gesture.pending)
        XCTAssertFalse(gesture.update(x:0,y:-80,now:0.81))
        XCTAssertTrue(gesture.pending)
        XCTAssertFalse(gesture.update(x:0,y:-80,now:3.29))
        XCTAssertTrue(gesture.update(x:0,y:-80,now:3.31))
        XCTAssertFalse(gesture.pending)
        XCTAssertFalse(gesture.update(x:0,y:-80,now:3.4))
        XCTAssertFalse(gesture.release(x:0,y:-80,now:3.5))
    }
    func testEarlyReleaseAndCancellationNeverBecomeSteering() {
        var release=QueueGesture(startedAt:0)
        XCTAssertFalse(release.update(x:0,y:-80,now:0.1))
        XCTAssertFalse(release.release(x:0,y:-80,now:0.4),"The final sample must detect pending hold even between timer ticks")
        var cancel=QueueGesture(startedAt:0)
        XCTAssertFalse(cancel.update(x:0,y:-80,now:0.1))
        cancel.cancel()
        XCTAssertFalse(cancel.release(x:0,y:-80,now:0.2))
        XCTAssertFalse(cancel.update(x:0,y:-80,now:2))
    }
    func testMovementRestartsPendingHoldAndDownDoesNotClaimQueue() {
        var gesture=QueueGesture(startedAt:0)
        XCTAssertFalse(gesture.update(x:0,y:-80,now:0.1))
        XCTAssertFalse(gesture.update(x:0,y:-80,now:0.31))
        XCTAssertFalse(gesture.update(x:0,y:-40,now:0.4))
        XCTAssertTrue(gesture.pending)
        XCTAssertFalse(gesture.release(x:0,y:-80,now:0.5))
        var down=QueueGesture(startedAt:0)
        XCTAssertFalse(down.update(x:0,y:80,now:0.1))
        XCTAssertFalse(down.claimed)
        XCTAssertFalse(down.release(x:0,y:80,now:0.2))
    }
    func testReleaseCannotCommitQueueEvenIfTimerWasDelayedAndInvalidCoordinatesCancel() {
        var gesture=QueueGesture(startedAt:0)
        XCTAssertFalse(gesture.update(x:0,y:-80,now:0.1))
        XCTAssertFalse(gesture.release(x:0,y:-80,now:3.31))
        XCTAssertFalse(gesture.committed)
        XCTAssertFalse(gesture.release(x:0,y:-80,now:3.5))
        var invalid=QueueGesture(startedAt:0)
        XCTAssertFalse(invalid.update(x:.nan,y:-80,now:0.1))
        XCTAssertFalse(invalid.release(x:0,y:-80,now:0.2))
    }
    func testSwipeCanFinishTravellingBeforeHoldAndCancelledReleaseNeverCommits() {
        var gesture=QueueGesture(startedAt:0)
        XCTAssertFalse(gesture.update(x:0,y:-60,now:0.1))
        XCTAssertFalse(gesture.update(x:0,y:-85,now:0.2))
        XCTAssertFalse(gesture.update(x:0,y:-110,now:0.3))
        XCTAssertFalse(gesture.update(x:0,y:-110,now:0.51))
        XCTAssertTrue(gesture.pending)
        XCTAssertTrue(gesture.update(x:0,y:-110,now:3.51))
        var cancelled=QueueGesture(startedAt:0)
        XCTAssertFalse(cancelled.update(x:0,y:-80,now:0.1))
        XCTAssertFalse(cancelled.release(x:0,y:-80,now:1,cancelled:true))
    }
    func testCompletedHoldStaysCommittedForLongHoldAndNeverResubmits() {
        var gesture=QueueGesture(startedAt:0)
        XCTAssertFalse(gesture.update(x:0,y:-80,now:0.1))
        XCTAssertFalse(gesture.update(x:0,y:-80,now:0.31))
        XCTAssertFalse(gesture.update(x:0,y:-110,now:0.4))
        XCTAssertTrue(gesture.pending)
        XCTAssertFalse(gesture.update(x:0,y:-110,now:0.9))
        XCTAssertTrue(gesture.update(x:0,y:-110,now:3.61))
        XCTAssertTrue(gesture.committed)
        XCTAssertFalse(gesture.update(x:0,y:-110,now:10))
        XCTAssertTrue(gesture.committed)
        XCTAssertFalse(gesture.release(x:0,y:-110,now:11))
    }
    func testForgivingSwipeThresholdsAndQueueHoldRemainSeparate() {
        for sign in [-1.0,1.0] {
            XCTAssertEqual(ComposerSwipe.direction(x:20,y:sign*20,duration:1),sign<0 ? .up : .down)
            XCTAssertNil(ComposerSwipe.direction(x:0,y:sign*19,duration:0.2))
            XCTAssertNil(ComposerSwipe.direction(x:21,y:sign*20,duration:0.2))
            XCTAssertNil(ComposerSwipe.direction(x:0,y:sign*20,duration:1.01))
        }
        var gesture=QueueGesture(startedAt:0)
        XCTAssertFalse(gesture.update(x:20,y:-20,now:0.1))
        XCTAssertTrue(gesture.claimed)
        XCTAssertFalse(gesture.update(x:20,y:-20,now:0.31))
        XCTAssertTrue(gesture.pending)
        XCTAssertFalse(gesture.update(x:20,y:-20,now:3.29))
        XCTAssertTrue(gesture.update(x:20,y:-20,now:3.31))
        XCTAssertFalse(gesture.release(x:20,y:-20,now:4))
    }
    func testQueueShortcutIsSeparateAndRejectsConflict() {
        func configured(_ json:String)->Bool { QueueShortcut.isConfigured(Data(json.utf8)) }
        XCTAssertTrue(configured("[{\"command\":\"composer.queue\",\"key\":\"Control+Option+Shift+Q\"}]"))
        XCTAssertFalse(configured("[{\"command\":\"composer.steer\",\"key\":\"Ctrl+Alt+Shift+Q\"}]"))
        XCTAssertFalse(configured("[{\"command\":\"composer.queue\",\"key\":\"Ctrl+Alt+Shift+Q\"},{\"command\":\"other\",\"key\":\"Ctrl+Alt+Shift+Q\"}]"))
    }
    func testQueueRequestIsIdentifiedAndDeduplicatedWithoutRecordingID() async throws {
        actor Count { var count=0;func next() { count+=1 } }
        let count=Count()
        let service=WakeService { request in
            await count.next()
            return WakeReceipt(id:request.id,outcome:.queueSent,message:"Queue command sent")
        }
        let request=WakeRequest(action:.sendQueue)
        XCTAssertEqual(try JSONDecoder().decode(WakeRequest.self,from:JSONEncoder().encode(request)),request)
        let first=await service.handle(request),second=await service.handle(request)
        XCTAssertEqual(first,second);XCTAssertEqual(first.outcome,.queueSent)
        let total=await count.count;XCTAssertEqual(total,1)
        XCTAssertEqual(try JSONDecoder().decode(WakeReceipt.self,from:JSONEncoder().encode(first)),first)
    }
}
