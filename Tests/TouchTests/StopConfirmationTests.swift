// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
import TouchCore

final class StopConfirmationTests: XCTestCase {
    func testStaleReadsDuringRerenderRecoverWithoutPrematureFailure() {
        var check=StopConfirmation(maxObservations:6)
        XCTAssertEqual(check.observe(.unavailable),.pending)
        XCTAssertEqual(check.observe(.recording),.pending)
        XCTAssertEqual(check.observe(.unavailable),.pending)
        XCTAssertEqual(check.observe(.stopped),.pending)
        XCTAssertEqual(check.observe(.stopped),.confirmed)
    }
    func testInterruptedEvidenceDoesNotConfirmStopped() {
        var check=StopConfirmation(maxObservations:5)
        XCTAssertEqual(check.observe(.stopped),.pending)
        XCTAssertEqual(check.observe(.unavailable),.pending)
        XCTAssertEqual(check.observe(.stopped),.pending)
        XCTAssertEqual(check.observe(.recording),.pending)
        XCTAssertEqual(check.observe(.stopped),.unconfirmed)
    }
    func testPersistentUnavailableOrRecordingIsBoundedAndNotSuccess() {
        for sample in [StopConfirmation.Observation.unavailable,.recording] {
            var check=StopConfirmation(maxObservations:2)
            XCTAssertEqual(check.observe(sample),.pending)
            XCTAssertEqual(check.observe(sample),.unconfirmed)
            XCTAssertEqual(check.observe(.stopped),.unconfirmed)
        }
    }
}
