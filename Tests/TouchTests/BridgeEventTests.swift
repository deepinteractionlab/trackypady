// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
#if os(macOS)
import XCTest
import TouchCore
@testable import TrackypadyBridge

final class BridgeEventTests: XCTestCase {
    func testStopFailureHistoryRetainsKnownReasonAndRejectsArbitraryText() {
        let request = WakeRequest(action: .prepareResponseStop)
        for (message, expected) in [
            ("Cannot verify the current Codex run", "Codex run log not found"),
            ("Cannot read the Codex run log", "Codex run log could not be read"),
            ("Bring the intended Codex chat forward before stopping", "Codex was not in front"),
            ("Stop window check failed: window document (AX -25204)", "Stop window check failed: window document (AX -25204)"),
            ("Stop window check failed: private draft (AX -25204)", "Command failed"),
            ("private test payload", "Command failed")
        ] {
            let receipt = WakeReceipt(id: request.id, outcome: .failed, message: message)
            let event = BridgeEvent(request: request, receipt: receipt)
            XCTAssertEqual(event.result, expected)
            XCTAssertTrue(event.failed)
        }
    }

    func testStopPathIsBridgeOnlyDetailAndDoesNotChangeSummary() {
        let request = WakeRequest(action: .stopResponse)
        for path in [CodexStopBinding.Path.full, .limited] {
            let receipt = WakeReceipt(id: request.id, outcome: .stopPressed, message: "private payload")
            let event = BridgeEvent(request: request, receipt: receipt, stopPath: path)
            XCTAssertEqual(event.title, "Stop")
            XCTAssertEqual(event.result, "Stop shortcut sent")
            XCTAssertEqual(event.stopPath?.detail, "Path: " + path.rawValue)
            XCTAssertFalse(event.failed)
        }
        let failed = BridgeEvent(request: request, receipt: WakeReceipt(id: request.id, outcome: .failed, message: "private payload"), stopPath: .limited)
        XCTAssertNil(failed.stopPath)
        XCTAssertEqual(failed.result, "Command failed")
    }

    func testCommandHistoryUsesProtocolOutcomeAndExcludesFreeText() {
        let request = WakeRequest(action: .sendQueue)
        let success = WakeReceipt(id: request.id, outcome: .queueSent, message: "private test payload")
        let event = BridgeEvent(request: request, receipt: success)
        XCTAssertEqual(event.title, "Queue")
        XCTAssertEqual(event.result, "Shortcut sent")
        XCTAssertEqual(event.requestID, request.id)
        let failure = WakeReceipt(id: request.id, outcome: .failed, message: "private test payload", failureReason: .composerFocus)
        let rejected = BridgeEvent(request: request, receipt: failure)
        XCTAssertTrue(rejected.failed)
        XCTAssertEqual(rejected.result, "Main chat input needs focus")
    }
}
#endif
