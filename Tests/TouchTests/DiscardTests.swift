// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
import TouchCore

final class DiscardTests: XCTestCase {
    func testDownSwipeOverlappingEmptyDraftCannotActAfterReceipt() {
        var gate = DiscardGestureGate()
        let id = UUID()
        gate.begin(id)
        XCTAssertFalse(gate.repeatDown(during: id))
        XCTAssertFalse(gate.finish(id, selected: false))
        XCTAssertFalse(gate.repeatDown(during: id))
        XCTAssertNil(gate.pendingID)
    }

    func testSecondDownSurvivesSelectionReceiptInEitherOrder() {
        let id = UUID()
        var gate = DiscardGestureGate()
        gate.begin(id)
        XCTAssertFalse(gate.repeatDown(during: id))
        XCTAssertFalse(gate.repeatDown(during: id))
        XCTAssertTrue(gate.finish(id, selected: true))
        XCTAssertFalse(gate.repeatDown(during: id))

        gate.begin(id)
        XCTAssertFalse(gate.finish(id, selected: true))
        XCTAssertTrue(gate.repeatDown(during: id))
        XCTAssertFalse(gate.repeatDown(during: id))
    }

    func testNewDiscardInvalidatesTouchesFromEarlierSelection() {
        var gate = DiscardGestureGate()
        let first = UUID(), second = UUID()
        gate.begin(first)
        XCTAssertFalse(gate.finish(first, selected: true))
        gate.begin(second)
        XCTAssertFalse(gate.repeatDown(during: first))
        XCTAssertFalse(gate.finish(first, selected: false))
        XCTAssertEqual(gate.pendingID, second)
        XCTAssertFalse(gate.finish(second, selected: true))
    }

    func testSelectionStateDeterminesActionIncludingManualPartialSelection() {
        XCTAssertEqual(DiscardSelection.action(textUTF16Length:10,location:4,length:0),.selectAll)
        XCTAssertEqual(DiscardSelection.action(textUTF16Length:10,location:0,length:10),.deleteSelection)
        XCTAssertEqual(DiscardSelection.action(textUTF16Length:10,location:3,length:2),.deleteSelection)
        for range in [(-1,2),(0,-1),(11,0),(8,3),(1,Int.max)] {
            XCTAssertNil(DiscardSelection.action(textUTF16Length:10,location:range.0,length:range.1))
        }
        XCTAssertNil(DiscardSelection.action(textUTF16Length:0,location:0,length:0))
        let text="a😀b"
        XCTAssertEqual(DiscardSelection.action(textUTF16Length:text.utf16.count,location:1,length:2),.deleteSelection)
    }
    func testSelectionConfirmationAllowsOnlyTerminalParagraphBreaks() {
        XCTAssertTrue(DiscardSelection.isComplete(text:"hello\n",location:0,length:5))
        XCTAssertTrue(DiscardSelection.isComplete(text:"😀\n",location:0,length:2))
        XCTAssertFalse(DiscardSelection.isComplete(text:"hello!",location:0,length:5))
        XCTAssertFalse(DiscardSelection.isComplete(text:"hello ",location:0,length:5))
        XCTAssertFalse(DiscardSelection.isComplete(text:"hello",location:1,length:4))
        XCTAssertFalse(DiscardSelection.isComplete(text:"hello",location:0,length:0))
        XCTAssertFalse(DiscardSelection.isComplete(text:"hello",location:0,length:99))
    }
    func testDeletionConfirmationHandlesEmptyEditorParagraphWithoutHidingText() {
        XCTAssertTrue(DiscardSelection.matchesAfterDelete(observed:"",expected:"\n"))
        XCTAssertTrue(DiscardSelection.matchesAfterDelete(observed:"\n",expected:""))
        XCTAssertTrue(DiscardSelection.matchesAfterDelete(observed:"left",expected:"left"))
        XCTAssertFalse(DiscardSelection.matchesAfterDelete(observed:"left",expected:""))
        XCTAssertFalse(DiscardSelection.matchesAfterDelete(observed:" ",expected:""))
        XCTAssertFalse(DiscardSelection.matchesAfterDelete(observed:"left\n",expected:"left"))
    }
    func testSelectionStatusAndReceiptRoundTrip() throws {
        let status=BridgeStatus(codexForeground:true,dictation:.idle,discardSelected:true)
        let receipt=WakeReceipt(id:UUID(),outcome:.draftSelected,message:"Draft selected",status:status)
        XCTAssertEqual(try JSONDecoder().decode(WakeReceipt.self,from:JSONEncoder().encode(receipt)),receipt)
        let requested=WakeReceipt(id:UUID(),outcome:.draftEditRequested,message:"Delete requested · confirmation unavailable")
        XCTAssertEqual(try JSONDecoder().decode(WakeReceipt.self,from:JSONEncoder().encode(requested)),requested)
    }
    func testVerticalSwipesMirrorEachOther() {
        XCTAssertEqual(ComposerSwipe.direction(x:12,y:-85,duration:0.3),.up)
        XCTAssertEqual(ComposerSwipe.direction(x:12,y:85,duration:0.3),.down)
        for sign in [-1.0,1.0] {
            XCTAssertNil(ComposerSwipe.direction(x:0,y:sign*19,duration:0.2))
            XCTAssertNil(ComposerSwipe.direction(x:86,y:sign*85,duration:0.3))
            XCTAssertNil(ComposerSwipe.direction(x:0,y:sign*85,duration:1.01))
            XCTAssertNil(ComposerSwipe.direction(x:0,y:sign*85,duration:0.3,cancelled:true))
            XCTAssertNil(ComposerSwipe.direction(x:.nan,y:sign*85,duration:0.3))
        }
    }
    func testDiscardReceiptRoundTripAndDeduplication() async throws {
        actor Count { var count=0;func increment() { count+=1 } }
        let count=Count()
        let service=WakeService { request in
            await count.increment()
            return WakeReceipt(id:request.id,outcome:.draftDiscarded,message:"Draft discarded")
        }
        let request=WakeRequest(action:.discardDraft)
        XCTAssertEqual(try JSONDecoder().decode(WakeRequest.self,from:JSONEncoder().encode(request)),request)
        let first=await service.handle(request),second=await service.handle(request)
        XCTAssertEqual(first.outcome,.draftDiscarded);XCTAssertEqual(first,second)
        let total=await count.count;XCTAssertEqual(total,1)
        XCTAssertEqual(try JSONDecoder().decode(WakeReceipt.self,from:JSONEncoder().encode(first)),first)
    }
}
