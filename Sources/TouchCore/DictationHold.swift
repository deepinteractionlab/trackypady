// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Pairs begin/end commands even if fingers lift before a start receipt arrives.
public struct DictationHold: Sendable {
    public enum Phase: String,Sendable { case idle,starting,recording,stopping }
    public private(set) var phase=Phase.idle
    public private(set) var recordingID: UUID?
    private var released=false
    private var pending: WakeRequest?
    public init() {}
    public mutating func begin(afterScratch scratchID: UUID? = nil) -> WakeRequest? {
        guard phase == .idle else { return nil }
        let session=UUID();recordingID=session;released=false;phase = .starting
        let request=WakeRequest(action:.startDictation,recordingID:session,scratchID:scratchID);pending=request;return request
    }
    public mutating func end() -> WakeRequest? {
        released=true
        guard phase == .recording,let recordingID else { return nil }
        phase = .stopping
        let request=WakeRequest(action:.stopDictation,recordingID:recordingID);pending=request;return request
    }
    public mutating func receive(_ receipt: WakeReceipt) -> WakeRequest? {
        guard let request=pending,receipt.id == request.id else { return nil }
        pending=nil
        if receipt.outcome == .failed { reset();return nil }
        if request.action == .startDictation,receipt.outcome == .dictationRecording {
            phase = .recording
            return released ? end() : nil
        }
        if request.action == .stopDictation,receipt.outcome == .dictationStopped { reset();return nil }
        reset();return nil
    }
    public mutating func reset() { phase = .idle;recordingID=nil;released=false;pending=nil }
}

/// A single continuous three-finger contact can claim its own Stop receipt once.
public struct ScratchDictationHandoff {
    private var waiting: UUID?
    private var holding = false

    public init() {}

    public mutating func recognize(_ id: UUID, contacts: Int) {
        waiting = contacts == 3 ? id : nil
    }

    public mutating func acknowledge(_ id: UUID?, receipt: WakeReceipt) -> Bool {
        guard let id, waiting == id else { return false }
        waiting = nil
        holding = receipt.outcome == .stopPressed && receipt.dictateAfterStop == true
        return holding
    }

    /// Returns true only when the caller must release a dictation hold.
    public mutating func release() -> Bool {
        defer { waiting = nil; holding = false }
        return holding
    }
}
