// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
@preconcurrency import Network
import TouchCore
@testable import TouchLink

@MainActor
final class DualTouchServerTests: XCTestCase {
    func testOfflinePhoneRecognizesPersistedForgetNoticeOnNextLookup() async throws {
        let store = TouchPairingStore(namespace: "com.deepinteractionlab.trackypady.tests." + UUID().uuidString)
        defer { try? store.forget(.bridge) }
        let old = try store.rotateBridgePairing()
        let replacement = try store.rotateBridgePairing()
        let current = try store.rotateBridgePairing()
        let persisted = try XCTUnwrap(store.load(.bridge))
        XCTAssertEqual(persisted.notices, [RevocationNotice(code: old.code), RevocationNotice(code: replacement.code)])
        XCTAssertFalse(persisted.notices.contains(RevocationNotice(code: current.code)))
        let server = RevocationAdvertisements()
        server.publish(persisted.notices, port: 49155)
        defer { server.stop() }
        let notified = expectation(description: "Offline phone receives its own revocation through Bonjour")
        notified.assertForOverFulfill = false
        let browser = RevocationAdvertisements.browse(for: RevocationNotice(code: old.code)) { notified.fulfill() }
        defer { browser.cancel() }
        await fulfillment(of: [notified], timeout: 10)
    }

    func testOneAuthenticatedOwnerAndImmediateReuseAfterQuit() async throws {
        let code = TouchPairing.code()
        let initial = BridgeStatus(codexForeground: true, dictation: .idle)
        var actions: [UUID] = []
        var connections = 0
        var finalDisconnect: XCTestExpectation?
        let released = expectation(description: "Owner quit")
        released.assertForOverFulfill = false
        var paired: UUID?
        let server = DualTouchServer(authorizePhone: { attempt in
            if paired == nil { paired = attempt.installation }
            return paired == attempt.installation
        }, initialStatus: { initial }, onConnectionState: { state in
            if state == .connected { connections += 1 }
            if state == .disconnected {
                released.fulfill()
                finalDisconnect?.fulfill()
            }
        }, onRequest: { request, reply in
            actions.append(request.id)
            reply(WakeReceipt(id: request.id, outcome: .foreground, message: ""))
        })
        let listener = try NWListener(using: TouchPairing.parameters(code: code, loopbackOnly: true))
        let listening = expectation(description: "Listening on loopback")
        listener.stateUpdateHandler = { state in if case .ready = state { listening.fulfill() } }
        listener.newConnectionHandler = { peer in MainActor.assumeIsolated { server.accept(peer) } }
        listener.start(queue: .main)
        defer { listener.cancel() }
        await fulfillment(of: [listening], timeout: 3)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: try XCTUnwrap(listener.port))
        func phone() throws -> LocalChannel {
            LocalChannel(NWConnection(to: endpoint, using: try TouchPairing.parameters(code: code, loopbackOnly: true)))
        }
        let original = PhoneConnectionAttempt(installation: UUID(), sequence: 1, deviceName: "Sandra’s iPhone")
        let first = try phone()
        let accepted = expectation(description: "Initial status delivered at acceptance")
        let result = expectation(description: "Owner receives receipt")
        let request = WakeRequest()
        first.onFrame = { frame in
            switch frame {
            case .available: first.send(.claim(original))
            case .accepted(let status): XCTAssertEqual(status, initial); accepted.fulfill()
            case .receipt(let receipt): XCTAssertEqual(receipt.id, request.id); result.fulfill()
            default: XCTFail("Unexpected frame")
            }
        }
        first.start()
        await fulfillment(of: [accepted], timeout: 3)
        XCTAssertEqual(server.connectedPhoneName, original.deviceName)
        let session = try XCTUnwrap(server.connectedSessionID)
        let loser = try phone()
        let rejected = expectation(description: "Second peer cannot submit a gesture")
        loser.onFrame = { frame in
            if case .available = frame { loser.send(.claim(PhoneConnectionAttempt(installation: UUID(), sequence: 2))); loser.send(.request(WakeRequest())) }
        }
        loser.onClose = { rejected.fulfill() }
        loser.start()
        await fulfillment(of: [rejected], timeout: 3)
        XCTAssertEqual(server.connectedSessionID, session)
        XCTAssertEqual(server.connectedPhoneName, original.deviceName)
        first.send(.request(request))
        await fulfillment(of: [result], timeout: 3)
        XCTAssertEqual(actions, [request.id])
        // Simulate a killed process whose socket still appears live to the Mac.
        let replacement = try phone()
        let reconnected = expectation(description: "Fresh phone process acquires a new session")
        replacement.onFrame = { frame in
            if case .available = frame { replacement.send(.claim(PhoneConnectionAttempt(installation: original.installation, sequence: 2, deviceName: "Lab iPhone"))) }
            if case .accepted = frame { reconnected.fulfill() }
        }
        replacement.start()
        await fulfillment(of: [released, reconnected], timeout: 3)
        XCTAssertEqual(connections, 2)
        XCTAssertNotEqual(server.connectedSessionID, session)
        XCTAssertEqual(server.connectedPhoneName, "Lab iPhone")
        finalDisconnect = expectation(description: "Replacement disconnected")
        replacement.close()
        await fulfillment(of: [try XCTUnwrap(finalDisconnect)], timeout: 3)
        finalDisconnect = nil
        XCTAssertNil(server.connectedPhoneName)
        let other = try phone()
        let refused = expectation(description: "Other phone refused while paired owner offline")
        other.onFrame = { frame in
            if case .available = frame { other.send(.claim(PhoneConnectionAttempt(installation: UUID(), sequence: 1))) }
            if case .accepted = frame { XCTFail("Unexpected second paired phone") }
        }
        other.onClose = { refused.fulfill() }
        other.start()
        await fulfillment(of: [refused], timeout: 3)
        let nextAccepted = expectation(description: "Paired phone reconnected")
        let finalPeer = try phone()
        let next = PhoneConnectionAttempt(installation: original.installation, sequence: 3)
        let revoked = expectation(description: "Former owner receives the reset notice")
        let disconnected = expectation(description: "Former owner disconnects after the notice")
        finalPeer.onFrame = { frame in
            if case .available = frame { finalPeer.send(.claim(next)) }
            if case .accepted = frame { nextAccepted.fulfill() }
            if case .pairingRevoked = frame { revoked.fulfill() }
        }
        finalPeer.onClose = { disconnected.fulfill() }
        finalPeer.start()
        await fulfillment(of: [nextAccepted], timeout: 3)
        XCTAssertEqual(server.connectedPhoneName, next.deviceName)
        defer { server.stop() }
        server.replacePairing(code: TouchPairing.code())
        XCTAssertNil(server.connectedPhoneName)
        XCTAssertNil(server.connectedSessionID)
        finalPeer.send(.request(WakeRequest()))
        await fulfillment(of: [revoked, disconnected], timeout: 3, enforceOrder: true)
        XCTAssertEqual(actions, [request.id], "The old session must lose command access before notice is sent")
    }
}
