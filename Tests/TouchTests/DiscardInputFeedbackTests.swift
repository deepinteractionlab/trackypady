// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
import TouchCore
import TouchLink

final class DiscardInputFeedbackTests: XCTestCase {
    func testOnlyMatchingResolvedInputIsAcknowledgedOnce() {
        var feedback=DiscardInputFeedback()
        let first=UUID(),second=UUID()
        feedback.begin(first)
        XCTAssertNil(feedback.receive(DiscardInputAcknowledgement(requestID:second,action:.discarding)))
        XCTAssertEqual(feedback.receive(DiscardInputAcknowledgement(requestID:first,action:.selecting)),.draftSelected)
        XCTAssertNil(feedback.receive(DiscardInputAcknowledgement(requestID:first,action:.discarding)))
        feedback.begin(second)
        XCTAssertNil(feedback.receive(DiscardInputAcknowledgement(requestID:first,action:.selecting)))
        XCTAssertEqual(feedback.receive(DiscardInputAcknowledgement(requestID:second,action:.discarding)),.draftDiscarded)
        feedback.reset()
        XCTAssertNil(feedback.receive(DiscardInputAcknowledgement(requestID:second,action:.discarding)))
    }
    func testInputAcknowledgementCanArriveBeforeAnUnconfirmedEditReceipt() throws {
        let code="0123456789ABCDEF01234567"
        let hello=try BluetoothPairing.hello(code:code),welcome=try BluetoothPairing.welcome(to:hello.packet,code:code)
        var mac=welcome.session
        var phone=try BluetoothPairing.finish(packet:welcome.packet,code:code,phoneNonce:hello.nonce)
        let request=WakeRequest(action:.discardDraft)
        var feedback=DiscardInputFeedback();feedback.begin(request.id)
        let input=DiscardInputAcknowledgement(requestID:request.id,action:.discarding)
        let decoded=try JSONDecoder().decode(DiscardInputAcknowledgement.self,from:phone.open(mac.seal(JSONEncoder().encode(input))))
        XCTAssertEqual(feedback.receive(decoded),.draftDiscarded)
        let receipt=WakeReceipt(id:request.id,outcome:.draftEditRequested,message:"Delete requested · confirmation unavailable")
        XCTAssertEqual(try JSONDecoder().decode(WakeReceipt.self,from:phone.open(mac.seal(JSONEncoder().encode(receipt)))).outcome,.draftEditRequested)
        XCTAssertNil(feedback.receive(decoded))
    }
    func testUnknownDiscardIntentCannotRequestArbitraryFeedback() throws {
        let data=Data("{\"version\":1,\"kind\":\"discardInput\",\"requestID\":\"\(UUID())\",\"action\":\"arbitrary\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(DiscardInputAcknowledgement.self,from:data))
    }
}
