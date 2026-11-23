// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
/// Failed or transitional reads cannot establish that recording stopped.
public struct StopConfirmation: Sendable {
    public enum Observation: Sendable { case recording,stopped,unavailable }
    public enum Outcome: Equatable,Sendable { case pending,confirmed,unconfirmed }
    private var remaining: Int
    private var stoppedSamples=0
    private var outcome=Outcome.pending
    public init(maxObservations: Int=20) { remaining=max(1,maxObservations) }
    public mutating func observe(_ observation: Observation) -> Outcome {
        guard outcome == .pending else { return outcome }
        remaining-=1
        if case .stopped=observation { stoppedSamples+=1 } else { stoppedSamples=0 }
        if stoppedSamples>=2 { outcome = .confirmed }
        else if remaining==0 { outcome = .unconfirmed }
        return outcome
    }
}
