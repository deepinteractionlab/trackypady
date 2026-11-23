// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
import TouchLink

final class BluetoothTests: XCTestCase {
    private let code="A0123456789BCDEF01234567"
    private func paired() throws -> (BluetoothSession,BluetoothSession) {
        let hello=try BluetoothPairing.hello(code:code)
        let welcome=try BluetoothPairing.welcome(to:hello.packet,code:code)
        return (try BluetoothPairing.finish(packet:welcome.packet,code:code,phoneNonce:hello.nonce),welcome.session)
    }
    func testMutualHandshakeAndBidirectionalPayloads() throws {
        var (phone,mac)=try paired()
        let request=Data("wakeCodex".utf8),receipt=Data("foreground".utf8)
        XCTAssertEqual(try mac.open(phone.seal(request)),request)
        XCTAssertEqual(try phone.open(mac.seal(receipt)),receipt)
    }
    func testWrongSecretAndUnrelatedWelcomeCannotAuthenticate() throws {
        let hello=try BluetoothPairing.hello(code:code)
        XCTAssertThrowsError(try BluetoothPairing.welcome(to:hello.packet,code:"B0123456789BCDEF01234567"))
        let welcome=try BluetoothPairing.welcome(to:hello.packet,code:code)
        let unrelated=try BluetoothPairing.hello(code:code)
        XCTAssertThrowsError(try BluetoothPairing.finish(packet:welcome.packet,code:code,phoneNonce:unrelated.nonce))
    }
    func testReplayReorderAndReflectionAreRejected() throws {
        var (phone,mac)=try paired()
        let first=try phone.seal(Data([1])),second=try phone.seal(Data([2]))
        XCTAssertThrowsError(try mac.open(second))
        XCTAssertEqual(try mac.open(first),Data([1]))
        XCTAssertThrowsError(try mac.open(first))
        XCTAssertThrowsError(try phone.open(second))
        XCTAssertEqual(try mac.open(second),Data([2]))
    }
    func testTamperingAndPreviousSessionMessagesAreRejected() throws {
        var (phone,mac)=try paired()
        let packet=try phone.seal(Data([7]))
        var tampered=packet;tampered[tampered.count-1] ^= 1
        XCTAssertThrowsError(try mac.open(tampered))
        var (_,freshMac)=try paired()
        XCTAssertThrowsError(try freshMac.open(packet))
        XCTAssertEqual(try mac.open(packet),Data([7]))
    }
    func testMaximumPayloadSurvivesSmallBluetoothChunks() throws {
        var (phone,mac)=try paired()
        let payload=Data(repeating:42,count:4096)
        let framed=try BluetoothPairing.frame(phone.seal(payload))
        var decoder=BluetoothFrameDecoder(),packets:[Data]=[]
        for offset in stride(from:0,to:framed.count,by:20) {
            packets += try decoder.append(Data(framed.dropFirst(offset).prefix(20)))
        }
        XCTAssertEqual(packets.count,1)
        XCTAssertEqual(try mac.open(XCTUnwrap(packets.first)),payload)
        XCTAssertThrowsError(try phone.seal(Data(repeating:1,count:4097)))
    }
    func testBoundedFramingRejectsInvalidLengthsAndHandlesMultipleFrames() throws {
        var decoder=BluetoothFrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0,0,0,0])))
        decoder=BluetoothFrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0,0,32,1])))
        decoder=BluetoothFrameDecoder()
        let combined=try BluetoothPairing.frame(Data([1]))+BluetoothPairing.frame(Data([2,3]))
        XCTAssertEqual(try decoder.append(combined),[Data([1]),Data([2,3])])
    }
    func testSavedQRIdentityFindsSameBluetoothService() throws {
        let original=try SavedTouchPairing(code:code)
        let restored=try JSONDecoder().decode(SavedTouchPairing.self,from:JSONEncoder().encode(original)).validated()
        let scanned=try TouchPairing.parseQR(TouchPairing.qrPayload(code:restored.code))
        XCTAssertEqual(BluetoothPairing.serviceID(code:scanned.code),BluetoothPairing.serviceID(code:code))
        XCTAssertNotEqual(BluetoothPairing.serviceID(code:code),BluetoothPairing.serviceID(code:"B0123456789BCDEF01234567"))
    }
}
