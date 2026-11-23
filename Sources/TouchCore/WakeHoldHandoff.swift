// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A held recording intent may wait for one explicitly requested wake, never outlive release.
public struct WakeHoldHandoff {
    private var wakeID: UUID?
    private var start: WakeRequest?
    public var isPending: Bool { start != nil }
    public init() {}
    public mutating func stage(_ request: WakeRequest,after wake: WakeRequest) -> Bool {
        guard start == nil,request.action == .startDictation,request.recordingID != nil,wake.action == .wakeCodex else { return false }
        wakeID=wake.id;start=request;return true
    }
    public mutating func complete(_ receipt: WakeReceipt,stillHeld: Bool) -> WakeRequest? {
        guard receipt.id == wakeID else { return nil }
        defer { cancel() }
        return receipt.outcome == .foreground && stillHeld ? start : nil
    }
    public mutating func cancel() { wakeID=nil;start=nil }
}
