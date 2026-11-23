// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
import TouchCore

final class WakeHoldHandoffTests: XCTestCase {
    func testSuccessfulWakeReleasesHeldStartExactlyOnce() {
        var handoff=WakeHoldHandoff()
        let wake=WakeRequest(),start=WakeRequest(action:.startDictation,recordingID:UUID())
        XCTAssertTrue(handoff.stage(start,after:wake))
        let receipt=WakeReceipt(id:wake.id,outcome:.foreground,message:"Codex brought forward")
        XCTAssertEqual(handoff.complete(receipt,stillHeld:true),start)
        XCTAssertFalse(handoff.isPending)
        XCTAssertNil(handoff.complete(receipt,stillHeld:true))
    }
    func testReleaseAndFailedWakeCannotStartRecordingLater() {
        let wake=WakeRequest(),start=WakeRequest(action:.startDictation,recordingID:UUID())
        let success=WakeReceipt(id:wake.id,outcome:.foreground,message:"")
        var released=WakeHoldHandoff();XCTAssertTrue(released.stage(start,after:wake))
        XCTAssertNil(released.complete(success,stillHeld:false));XCTAssertFalse(released.isPending)
        var cancelled=WakeHoldHandoff();XCTAssertTrue(cancelled.stage(start,after:wake));cancelled.cancel()
        XCTAssertNil(cancelled.complete(success,stillHeld:true))
        var failed=WakeHoldHandoff();XCTAssertTrue(failed.stage(start,after:wake))
        XCTAssertNil(failed.complete(WakeReceipt(id:wake.id,outcome:.failed,message:"Unavailable"),stillHeld:true))
        XCTAssertFalse(failed.isPending)
    }
    func testUnrelatedReceiptCannotReleaseOrReplacePendingStart() {
        var handoff=WakeHoldHandoff()
        let wake=WakeRequest(),start=WakeRequest(action:.startDictation,recordingID:UUID())
        XCTAssertTrue(handoff.stage(start,after:wake))
        XCTAssertFalse(handoff.stage(WakeRequest(action:.startDictation,recordingID:UUID()),after:wake))
        XCTAssertNil(handoff.complete(WakeReceipt(id:UUID(),outcome:.foreground,message:""),stillHeld:true))
        XCTAssertTrue(handoff.isPending)
        XCTAssertEqual(handoff.complete(WakeReceipt(id:wake.id,outcome:.foreground,message:""),stillHeld:true),start)
    }
    func testOnlyIdentifiedRecordingStartCanFollowExplicitWake() {
        var handoff=WakeHoldHandoff()
        XCTAssertFalse(handoff.stage(WakeRequest(action:.startDictation),after:WakeRequest()))
        XCTAssertFalse(handoff.stage(WakeRequest(action:.discardDraft),after:WakeRequest()))
        XCTAssertFalse(handoff.stage(WakeRequest(action:.startDictation,recordingID:UUID()),after:WakeRequest(action:.getStatus)))
    }
}
