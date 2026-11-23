// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
#if os(macOS)
import XCTest
import TouchCore
@testable import TrackypadyBridge

final class WiFiFailureFeedbackTests: XCTestCase {
    func testBluetoothReconnectNeverPresentsWiFiFailure() {
        var feedback = WiFiFailureFeedback()
        XCTAssertNil(feedback.receive(report: .init(localNetworkDenied: true), macDenied: true))
        XCTAssertNil(feedback.receive(report: .init(localNetworkDenied: true, requestID: UUID()), macDenied: true))
    }

    func testOnlyFailureFromExplicitWiFiRequestPresents() {
        var feedback = WiFiFailureFeedback()
        let requestID = UUID()
        feedback.begin(requestID: requestID)
        XCTAssertNil(feedback.receive(report: nil, macDenied: true))
        XCTAssertNil(feedback.receive(report: .init(localNetworkDenied: true), macDenied: true))
        XCTAssertNil(feedback.receive(report: .init(localNetworkDenied: true, requestID: UUID()), macDenied: true))
        XCTAssertEqual(feedback.receive(report: .init(localNetworkDenied: false, requestID: requestID), macDenied: true), .macPermission)
    }

    func testDismissedAlertStaysDismissedUntilNewExplicitAttempt() {
        var feedback = WiFiFailureFeedback()
        let requestID = UUID()
        feedback.begin(requestID: requestID)
        let failure = WiFiFailureReport(localNetworkDenied: true, requestID: requestID)
        XCTAssertEqual(feedback.receive(report: failure, macDenied: false), .phonePermission)
        XCTAssertNil(feedback.receive(report: failure, macDenied: false))
        XCTAssertNil(feedback.receive(report: nil, macDenied: false))
        XCTAssertNil(feedback.receive(report: .init(localNetworkDenied: true, requestID: requestID), macDenied: false))
        let retryID = UUID()
        feedback.begin(requestID: retryID)
        XCTAssertNil(feedback.receive(report: failure, macDenied: false))
        XCTAssertEqual(feedback.receive(report: .init(localNetworkDenied: true, requestID: retryID), macDenied: false), .phonePermission)
    }

    func testUnknownNoticeCanBeReplacedByConfirmedMacDenial() {
        var feedback = WiFiFailureFeedback()
        let requestID = UUID()
        feedback.begin(requestID: requestID)
        let failure = WiFiFailureReport(localNetworkDenied: false, requestID: requestID)
        XCTAssertEqual(feedback.receive(report: failure, macDenied: false), .unknown)
        XCTAssertNil(feedback.receive(report: failure, macDenied: false))
        XCTAssertEqual(feedback.receive(report: failure, macDenied: true), .macPermission)
        XCTAssertNil(feedback.receive(report: failure, macDenied: false))
    }

    func testCompletedOrCancelledAttemptCannotPresentLaterFailure() {
        var feedback = WiFiFailureFeedback()
        let requestID = UUID()
        feedback.begin(requestID: requestID)
        feedback.cancel()
        XCTAssertNil(feedback.receive(report: .init(localNetworkDenied: true, requestID: requestID), macDenied: true))
    }

    func testReportCorrelationSurvivesWireEncodingAndOldReportsStillDecode() throws {
        var request = WakeRequest(action: .getStatus)
        request.wifiFailure = WiFiFailureReport(localNetworkDenied: true, requestID: UUID())
        XCTAssertEqual(try JSONDecoder().decode(WakeRequest.self, from: JSONEncoder().encode(request)), request)
        let legacy = Data("{\"id\":\"\(UUID().uuidString)\",\"localNetworkDenied\":true}".utf8)
        XCTAssertNil(try JSONDecoder().decode(WiFiFailureReport.self, from: legacy).requestID)
    }
}
#endif
