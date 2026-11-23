// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
import TouchCore
import TouchLink

final class HapticPreviewTests: XCTestCase {
    func testTapPlaysOnceAndHoldReleaseStopsWithoutAnExtraOneShot() {
        var press=HapticPreviewPress()
        XCTAssertTrue(press.begin());XCTAssertFalse(press.begin())
        XCTAssertEqual(press.end(),.playOnce);XCTAssertEqual(press.end(),.none)
        XCTAssertTrue(press.begin());XCTAssertTrue(press.beginLoop());XCTAssertFalse(press.beginLoop())
        XCTAssertEqual(press.end(),.stop);XCTAssertFalse(press.beginLoop())
        XCTAssertTrue(press.begin());XCTAssertEqual(press.end(cancelled:true),.none)
        XCTAssertTrue(press.begin());XCTAssertTrue(press.beginLoop())
        XCTAssertEqual(press.end(cancelled:true),.stop)
    }
    func testAuthenticatedPreviewPushCanPrecedeAnOutstandingRequestReceipt() throws {
        let code="0123456789ABCDEF01234567"
        let hello=try BluetoothPairing.hello(code:code)
        let welcome=try BluetoothPairing.welcome(to:hello.packet,code:code)
        var mac=welcome.session
        var phone=try BluetoothPairing.finish(packet:welcome.packet,code:code,phoneNonce:hello.nonce)
        let request=WakeRequest(action:.getStatus)
        _ = try mac.open(phone.seal(JSONEncoder().encode(request)))
        let push=HapticPreviewPush(command:HapticPreviewCommand(sessionID:UUID(),cue:.wake))
        XCTAssertEqual(try JSONDecoder().decode(HapticPreviewPush.self,from:phone.open(mac.seal(JSONEncoder().encode(push)))),push)
        let receipt=WakeReceipt(id:request.id,outcome:.status,message:"")
        XCTAssertEqual(try JSONDecoder().decode(WakeReceipt.self,from:phone.open(mac.seal(JSONEncoder().encode(receipt)))).id,request.id)
    }
    func testLegacyPreviewStateDecodesWithoutPlaybackIndicator() throws {
        let data=Data("{\"enabled\":true,\"sessionID\":\"\(UUID())\",\"message\":\"Ready\"}".utf8)
        let state=try JSONDecoder().decode(HapticPreviewState.self,from:data)
        XCTAssertNil(state.playingCue);XCTAssertNil(state.looping)
    }
    func testLegacyMessagesStillDecodeWithoutPreviewFields() throws {
        let id=UUID()
        let request=Data("{\"version\":1,\"id\":\"\(id)\",\"action\":\"getStatus\"}".utf8)
        XCTAssertNil(try JSONDecoder().decode(WakeRequest.self,from:request).hapticPreview)
        let receipt=Data("{\"version\":1,\"id\":\"\(id)\",\"outcome\":\"status\",\"message\":\"\"}".utf8)
        XCTAssertNil(try JSONDecoder().decode(WakeReceipt.self,from:receipt).hapticPreview)
    }
    func testPreviewControlAndAcknowledgementRoundTripThroughAuthenticatedChannel() throws {
        let code="0123456789ABCDEF01234567"
        let hello=try BluetoothPairing.hello(code:code)
        let welcome=try BluetoothPairing.welcome(to:hello.packet,code:code)
        var mac=welcome.session
        var phone=try BluetoothPairing.finish(packet:welcome.packet,code:code,phoneNonce:hello.nonce)
        let session=UUID(),command=HapticPreviewCommand(sessionID:UUID(),cue:.recording,loop:true,reversed:true)
        let request=WakeRequest(action:.getStatus,hapticPreview:HapticPreviewState(enabled:true,sessionID:session,lastCommandID:command.id,message:"Preview started"))
        let received=try JSONDecoder().decode(WakeRequest.self,from:mac.open(phone.seal(JSONEncoder().encode(request))))
        XCTAssertEqual(received,request)
        let receipt=WakeReceipt(id:request.id,outcome:.status,message:"",hapticPreview:command)
        let response=try JSONDecoder().decode(WakeReceipt.self,from:phone.open(mac.seal(JSONEncoder().encode(receipt))))
        XCTAssertEqual(response.hapticPreview,command)
        XCTAssertEqual(response.hapticPreview?.reversed,true)
        let stop=HapticPreviewCommand(sessionID:session)
        XCTAssertNil(try JSONDecoder().decode(HapticPreviewCommand.self,from:JSONEncoder().encode(stop)).cue)
    }
    func testUnknownPatternsAndMissingSessionAreRejected() throws {
        let command=HapticPreviewCommand(sessionID:UUID(),cue:.wake)
        let data=try JSONEncoder().encode(command)
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        json["cue"]="arbitrary-file.ahap"
        XCTAssertThrowsError(try JSONDecoder().decode(HapticPreviewCommand.self,from:JSONSerialization.data(withJSONObject:json)))
        json["cue"]=HapticCue.wake.rawValue;json.removeValue(forKey:"sessionID")
        XCTAssertThrowsError(try JSONDecoder().decode(HapticPreviewCommand.self,from:JSONSerialization.data(withJSONObject:json)))
    }
}
