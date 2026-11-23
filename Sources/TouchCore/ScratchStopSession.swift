// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Joins a physical scratch with its asynchronous Mac preparation and stop receipts.
public struct ScratchStopSession {
    private enum Phase { case preparing, prepared, recognized, sent, awaitingHold, dictating }
    private var id: UUID?
    private var phase = Phase.preparing
    private var direction: ScratchGesture.Direction?
    private var handoff = ScratchDictationHandoff()

    public var isActive: Bool { id != nil }

    public init() {}

    public mutating func begin(_ id: UUID) -> WakeRequest? {
        guard self.id == nil else { return nil }
        self.id = id
        phase = .preparing
        return WakeRequest(action: .prepareResponseStop, scratchID: id)
    }

    public mutating func prepared(_ id: UUID, successful: Bool) -> WakeRequest? {
        guard self.id == id, phase == .preparing || phase == .recognized else { return nil }
        guard successful else { self = Self(); return nil }
        if phase == .recognized { return stop(id) }
        phase = .prepared
        return nil
    }

    public mutating func recognize(_ id: UUID, contacts: Int, direction: ScratchGesture.Direction? = nil) -> WakeRequest? {
        guard self.id == id, phase == .preparing || phase == .prepared else { return nil }
        self.direction = direction
        handoff.recognize(id, contacts: contacts)
        if phase == .prepared { return stop(id) }
        phase = .recognized
        return nil
    }

    private mutating func stop(_ id: UUID) -> WakeRequest {
        phase = .sent
        return WakeRequest(action: .stopResponse, scratchID: id)
    }

    public mutating func finishPan(_ id: UUID) {
        guard self.id == id, phase == .preparing || phase == .prepared else { return }
        self = Self()
    }

    public func confirmedDirection(for id: UUID?, receipt: WakeReceipt) -> ScratchGesture.Direction? {
        guard let id, self.id == id, phase == .sent, receipt.outcome == .stopPressed else { return nil }
        return direction
    }

    public mutating func acknowledge(_ id: UUID?, receipt: WakeReceipt) -> Bool {
        guard let id, self.id == id, phase == .sent else { return false }
        if handoff.acknowledge(id, receipt: receipt) {
            phase = .awaitingHold
            return true
        }
        self = Self()
        return false
    }

    public mutating func beginHeldDictation(_ id: UUID) -> Bool {
        guard self.id == id, phase == .awaitingHold else { return false }
        phase = .dictating
        return true
    }

    public mutating func release(_ id: UUID) -> Bool {
        guard self.id == id else { return false }
        if handoff.release() {
            let didBegin = phase == .dictating
            self = Self()
            return didBegin
        }
        return false
    }
}
