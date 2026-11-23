// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation
import TouchCore

/// Only a failure belonging to the user's current Wi-Fi switch may interrupt them.
struct WiFiFailureFeedback {
    enum Reason: Equatable { case macPermission, phonePermission, unknown }
    private var requestID: UUID?
    private var presented: Reason?

    mutating func begin(requestID: UUID) {
        self.requestID = requestID
        presented = nil
    }

    mutating func cancel() { self = Self() }

    mutating func receive(report: WiFiFailureReport?, macDenied: Bool) -> Reason? {
        guard let requestID, let report, report.requestID == requestID else { return nil }
        let reason: Reason = macDenied ? .macPermission : (report.localNetworkDenied ? .phonePermission : .unknown)
        // A late, explicit denial supersedes a timeout. Clearing a permission in
        // Settings does not turn the very same failure into another notification.
        guard presented == nil || (presented == .unknown && reason != .unknown) else { return nil }
        presented = reason
        return reason
    }
}
