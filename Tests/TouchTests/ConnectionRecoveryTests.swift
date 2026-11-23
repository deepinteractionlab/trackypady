// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
import Network
import TouchCore
import TouchLink

private actor ListeningPort {
    var value: UInt16?
    func set(_ value: UInt16) { self.value=value }
}

final class ConnectionRecoveryTests: XCTestCase,@unchecked Sendable {
    func testSilentPhoneTimesOutAndNewPhoneConnectsWithoutRestart() async throws {
        try await verifyRecovery(silent:true)
    }
    func testClosedPhoneReleasesSlotWithoutWaitingForTimeout() async throws {
        try await verifyRecovery(silent:false)
    }
    private func verifyRecovery(silent: Bool) async throws {
        let listening=expectation(description:"Listener ready")
        let connected=expectation(description:"First phone connected")
        connected.assertForOverFulfill=false
        let disconnected=expectation(description:"Stale phone released")
        disconnected.assertForOverFulfill=false
        let reconnected=expectation(description:"Replacement connected")
        reconnected.assertForOverFulfill=false
        let replied=expectation(description:"Replacement receives status")
        let port=ListeningPort(),code=TouchPairing.code()
        let first=TouchClient(onState:{ _,ready in if ready { connected.fulfill() } },onReceipt:{ _ in })
        let second=TouchClient(onState:{ _,ready in if ready { reconnected.fulfill() } },onReceipt:{ receipt in
            XCTAssertEqual(receipt.outcome,.status);replied.fulfill()
        })
        let server=TouchServer(onState:{ state in
            if state.hasPrefix("iPhone disconnected") { disconnected.fulfill() }
        },onRequest:{ request,reply in
            reply(WakeReceipt(id:request.id,outcome:.status,message:"Ready"))
        },inactivityTimeout:silent ? 0.6 : 30)
        server.onPort={ value in Task { await port.set(value);listening.fulfill() } }
        server.start(code:code,loopbackOnly:true)
        defer { first.stop();second.stop();server.stop() }
        await fulfillment(of:[listening],timeout:5)
        let capturedPort=await port.value
        let value=try XCTUnwrap(capturedPort)
        let endpoint=NWEndpoint.hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:value)!)
        first.connect(endpoint:endpoint,code:code,loopbackOnly:true)
        await fulfillment(of:[connected],timeout:5)
        if !silent { first.stop() }
        await fulfillment(of:[disconnected],timeout:3)
        second.connect(endpoint:endpoint,code:code,loopbackOnly:true)
        await fulfillment(of:[reconnected],timeout:5)
        second.send(WakeRequest(action:.getStatus))
        await fulfillment(of:[replied],timeout:5)
    }
}
