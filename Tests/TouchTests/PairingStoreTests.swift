// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
import TouchLink

final class PairingStoreTests: XCTestCase {
    func testPhoneForgetSurvivesRelaunchAndConfirmationPreservesNewPairing() throws {
        let namespace = "com.deepinteractionlab.trackypady.tests." + UUID().uuidString
        let store = TouchPairingStore(namespace: namespace)
        let old = try SavedTouchPairing(code: TouchPairing.code(), peripheralID: UUID())
        let next = try SavedTouchPairing(code: TouchPairing.code())
        defer {
            try? store.confirmPhoneForget(code: old.code)
            try? store.forget(.phone)
        }
        try store.save(old, for: .phone)
        try store.queuePhoneForget(old)
        try store.queuePhoneForget(old)
        let relaunched = TouchPairingStore(namespace: namespace)
        XCTAssertNil(try relaunched.load(.phone))
        XCTAssertEqual(try relaunched.pendingPhoneForgets(), [old])
        try relaunched.forget(.phone)
        try relaunched.save(next, for: .phone)
        XCTAssertEqual(try store.pendingPhoneForgets(), [old])
        try store.confirmPhoneForget(code: old.code)
        XCTAssertEqual(try store.pendingPhoneForgets(), [])
        XCTAssertEqual(try store.load(.phone), next)
    }

    func testPairingSurvivesNewStoreInstanceAndCanBeExplicitlyReset() throws {
        let namespace="com.deepinteractionlab.trackypady.tests.\(UUID().uuidString)"
        let store=TouchPairingStore(namespace:namespace)
        defer { try? store.forget(.bridge) }
        XCTAssertNil(try store.load(.bridge))
        let phone = PairedPhone(installation: UUID(), name: "Lab iPhone", pairedAt: Date(timeIntervalSince1970: 123456))
        var pairing=try SavedTouchPairing(code:TouchPairing.code(), phone:phone)
        pairing.prefersWiFi = true
        try store.save(pairing,for:.bridge)
        let relaunched=TouchPairingStore(namespace:namespace)
        XCTAssertEqual(try relaunched.load(.bridge),pairing)
        let replacement = try relaunched.rotateBridgePairing()
        XCTAssertNotEqual(replacement.code, pairing.code)
        XCTAssertNil(replacement.phone)
        XCTAssertNil(replacement.prefersWiFi)
        XCTAssertEqual(try store.load(.bridge),replacement)
        try store.forget(.bridge)
        XCTAssertNil(try relaunched.load(.bridge))
        XCTAssertNoThrow(try store.forget(.bridge))
    }
    func testLegacyPairingCanLearnTheAuthenticatedPeripheralWithoutPairingAgain() throws {
        let code = TouchPairing.code()
        let legacy = try SavedTouchPairing(code: code)
        let data = try JSONSerialization.data(withJSONObject: ["name": legacy.name, "code": code])
        let decoded = try JSONDecoder().decode(SavedTouchPairing.self, from: data).validated()
        XCTAssertNil(decoded.peripheralID)
        XCTAssertNil(decoded.prefersWiFi)
        let store = TouchPairingStore(namespace: "com.deepinteractionlab.trackypady.tests.\(UUID().uuidString)")
        defer { try? store.forget(.phone) }
        let updated = try SavedTouchPairing(code: decoded.code, peripheralID: UUID())
        try store.save(updated, for: .phone)
        XCTAssertEqual(try store.load(.phone), updated)
    }
    func testForgettingPhoneDoesNotDeleteBridgeIdentity() throws {
        let store=TouchPairingStore(namespace:"com.deepinteractionlab.trackypady.tests.\(UUID().uuidString)")
        defer { try? store.forget(.bridge);try? store.forget(.phone) }
        let bridge=try SavedTouchPairing(code:TouchPairing.code())
        let phone=try SavedTouchPairing(code:TouchPairing.code())
        try store.save(bridge,for:.bridge);try store.save(phone,for:.phone)
        try store.forget(.phone)
        XCTAssertNil(try store.load(.phone));XCTAssertEqual(try store.load(.bridge),bridge)
    }
    func testDecodedPairingCannotSubstituteAnArbitraryBonjourName() throws {
        let code=TouchPairing.code()
        let data=try JSONSerialization.data(withJSONObject:["name":"Unrelated service","code":code])
        let decoded=try JSONDecoder().decode(SavedTouchPairing.self,from:data)
        XCTAssertThrowsError(try decoded.validated())
        XCTAssertThrowsError(try SavedTouchPairing(code:"invalid"))
    }
}
