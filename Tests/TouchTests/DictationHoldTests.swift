// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
import TouchCore

final class DictationHoldTests: XCTestCase {
    func testScratchHandoffRequiresThreeContactsAndAMatchingSuccessfulStop() throws {
        let scratch = UUID()
        for contacts in [2, 3, 4] {
            for enabled: Bool? in [nil, false, true] {
                for outcome: WakeReceipt.Outcome in [.stopPressed, .noActiveResponse, .failed] {
                    var handoff = ScratchDictationHandoff()
                    handoff.recognize(scratch, contacts: contacts)
                    let sent = WakeReceipt(id: UUID(), outcome: outcome, message: "", dictateAfterStop: enabled)
                    let receipt = try JSONDecoder().decode(WakeReceipt.self, from: JSONEncoder().encode(sent))
                    XCTAssertFalse(handoff.acknowledge(UUID(), receipt: receipt))
                    let expected = contacts == 3 && enabled == true && outcome == .stopPressed
                    XCTAssertEqual(handoff.acknowledge(scratch, receipt: receipt), expected)
                    XCTAssertFalse(handoff.acknowledge(scratch, receipt: receipt))
                    XCTAssertEqual(handoff.release(), expected)
                    XCTAssertFalse(handoff.release())
                }
            }
        }
    }

    func testLiftingBeforeStopReceiptCannotStartRecording() {
        let scratch = UUID()
        var handoff = ScratchDictationHandoff()
        handoff.recognize(scratch, contacts: 3)
        XCTAssertFalse(handoff.release())
        let receipt = WakeReceipt(id: UUID(), outcome: .stopPressed, message: "", dictateAfterStop: true)
        XCTAssertFalse(handoff.acknowledge(scratch, receipt: receipt))
    }

    func testEarlyReleaseWaitsForStartThenStopsTheSameRecordingOnce() throws {
        var hold=DictationHold()
        let start=try XCTUnwrap(hold.begin())
        XCTAssertNil(hold.begin());XCTAssertNil(hold.end())
        let stop=try XCTUnwrap(hold.receive(WakeReceipt(id:start.id,outcome:.dictationRecording,message:"")))
        XCTAssertEqual(stop.action,.stopDictation);XCTAssertEqual(stop.recordingID,start.recordingID)
        XCTAssertEqual(hold.phase,.stopping);XCTAssertNil(hold.end())
        XCTAssertNil(hold.receive(WakeReceipt(id:start.id,outcome:.dictationRecording,message:"")))
        _=hold.receive(WakeReceipt(id:stop.id,outcome:.dictationStopped,message:""))
        XCTAssertEqual(hold.phase,.idle)
    }
    func testNormalReleaseAndUnrelatedReceipt() throws {
        var hold=DictationHold();let start=try XCTUnwrap(hold.begin())
        XCTAssertNil(hold.receive(WakeReceipt(id:UUID(),outcome:.dictationRecording,message:"")))
        XCTAssertEqual(hold.phase,.starting)
        XCTAssertNil(hold.receive(WakeReceipt(id:start.id,outcome:.dictationRecording,message:"")))
        XCTAssertEqual(hold.phase,.recording)
        XCTAssertNotNil(hold.end());XCTAssertEqual(hold.phase,.stopping)
    }
    func testFailureAndResetCannotStopAnUnrelatedRecording() throws {
        var hold=DictationHold();let start=try XCTUnwrap(hold.begin())
        _=hold.end();_=hold.receive(WakeReceipt(id:start.id,outcome:.failed,message:"Unavailable"))
        XCTAssertEqual(hold.phase,.idle);XCTAssertNil(hold.end())
        let newer=try XCTUnwrap(hold.begin());XCTAssertNotEqual(newer.recordingID,start.recordingID)
        hold.reset()
        XCTAssertNil(hold.receive(WakeReceipt(id:newer.id,outcome:.dictationRecording,message:"")))
        XCTAssertEqual(hold.phase,.idle)
    }
    func testReusingAnEventForAnotherCommandIsRejected() async {
        let service=WakeService { request in WakeReceipt(id:request.id,outcome:.foreground,message:"") }
        let request=WakeRequest();_=await service.handle(request)
        let conflicting=WakeRequest(id:request.id,action:.stopDictation,recordingID:UUID())
        let result=await service.handle(conflicting)
        XCTAssertEqual(result.outcome,.failed)
    }
    func testCommandsRequireRecordingIdentity() async {
        let service=WakeService { request in XCTFail("Unscoped dictation executed");return WakeReceipt(id:request.id,outcome:.failed,message:"") }
        let receipt=await service.handle(WakeRequest(action:.startDictation))
        XCTAssertEqual(receipt.outcome,.failed)
    }
}
