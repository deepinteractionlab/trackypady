// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
import TouchCore

final class SteeringTests: XCTestCase {
    func testSwipeRequiresDeliberateQuickUpwardRelease() {
        XCTAssertTrue(SteeringSwipe.qualifies(x:12,y:-85,duration:0.3))
        XCTAssertFalse(SteeringSwipe.qualifies(x:0,y:-19,duration:0.2))
        XCTAssertFalse(SteeringSwipe.qualifies(x:86,y:-85,duration:0.3))
        XCTAssertFalse(SteeringSwipe.qualifies(x:0,y:85,duration:0.3))
        XCTAssertFalse(SteeringSwipe.qualifies(x:0,y:-85,duration:1.01),"A swipe beyond the release window must not submit")
        XCTAssertFalse(SteeringSwipe.qualifies(x:0,y:-85,duration:0.3,cancelled:true))
        XCTAssertFalse(SteeringSwipe.qualifies(x:.nan,y:-85,duration:0.3))
    }
    func testNativeSteerBindingRejectsMissingWrongOrConflictingCommand() {
        func configured(_ text: String) -> Bool { SteeringShortcut.isConfigured(Data(text.utf8)) }
        XCTAssertTrue(configured("[{\"command\":\"composer.steer\",\"key\":\"Ctrl+Alt+Shift+S\"}]"))
        XCTAssertTrue(configured("[{\"command\":\"composer.steer\",\"key\":\"Shift+Control+Option+S\"}]"))
        XCTAssertFalse(configured("[]"))
        XCTAssertFalse(configured("[{\"command\":\"composer.queue\",\"key\":\"Ctrl+Alt+Shift+S\"}]"))
        XCTAssertFalse(configured("[{\"command\":\"composer.steer\",\"key\":\"Cmd+Alt+Shift+S\"}]"))
        XCTAssertFalse(configured("[{\"command\":\"composer.steer\",\"key\":\"Ctrl+Alt+Shift+S\"},{\"command\":\"composer.queue\",\"key\":\"Ctrl+Alt+Shift+S\"}]"))
    }
    func testSteeringNeedsNoDictationIdentityAndDeduplicates() async {
        actor Counter { var value=0;func increment() { value+=1 } }
        let counter=Counter()
        let service=WakeService { request in
            await counter.increment()
            return WakeReceipt(id:request.id,outcome:.steeringSent,message:"Observed")
        }
        let request=WakeRequest(action:.sendSteering)
        let first=await service.handle(request),second=await service.handle(request)
        XCTAssertEqual(first.outcome,.steeringSent);XCTAssertEqual(first,second)
        let count=await counter.value;XCTAssertEqual(count,1)
    }
    func testSendAndDraftPresentationRoundTripsWithoutTextPayload() throws {
        let status=BridgeStatus(codexForeground:true,dictation:.idle,submission:.sent,composerHasDraft:false)
        XCTAssertEqual(try JSONDecoder().decode(BridgeStatus.self,from:JSONEncoder().encode(status)),status)
        XCTAssertEqual(TouchPresentation.headline(connected:true,status:status),"Prompt\nSent")
        XCTAssertEqual(TouchPresentation.headline(connected:true,status:status,steeringPending:true),"Sending\nSteering")
        XCTAssertEqual(TouchPresentation.headline(connected:true,phase:.recording,status:status),"Recording")
        let uncertain=BridgeStatus(codexForeground:true,dictation:.idle,submission:.uncertain)
        XCTAssertEqual(TouchPresentation.headline(connected:true,phase:.stopping,status:uncertain),"Transcribing")
        let draft=BridgeStatus(codexForeground:true,dictation:.idle,composerHasDraft:true)
        XCTAssertEqual(TouchPresentation.headline(connected:true,status:draft),"Ready")
        XCTAssertEqual(TouchPresentation.headline(connected:true,status:BridgeStatus(codexForeground:true,dictation:.idle,submission:.uncertain)),"Ready")
    }
}
