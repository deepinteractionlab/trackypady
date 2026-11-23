// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics

public enum PadAction {
    case wake, beginHold, endHold(cancelled: Bool)
    case steer, queue, queueHold(Bool), queueReleased, discard, repeatDiscard(UUID)
    case beginScratch(UUID), completeScratch(UUID, contacts: Int, direction: ScratchGesture.Direction), releaseScratch(UUID), endScratch(UUID, ScratchGesture)
    case note(String)
}

/// One physical pan. UIKit supplies samples and elapsed time; this value owns arbitration.
public struct PadInteraction {
    public let id = UUID()
    private let started: TimeInterval
    private let timing: ScratchTiming
    private let discardAtTouchDown: UUID?
    private let allowsVertical: Bool
    private let minimumScratchContacts: Int
    private var scratch: ScratchGesture?
    private var scratchOrigin = CGPoint.zero
    private var mayJoinScratch: Bool
    private var queue: QueueGesture
    private var holdClaimed = false

    public init(contacts: Int, allowSingleFinger: Bool, timing: ScratchTiming,
                discardAtTouchDown: UUID?, now: TimeInterval) {
        started = now
        self.timing = timing
        self.discardAtTouchDown = discardAtTouchDown
        allowsVertical = allowSingleFinger || contacts == 3
        let minimum = ScratchGesture.minimumContacts(allowSingleFinger: allowSingleFinger)
        minimumScratchContacts = minimum
        scratch = contacts >= minimum ? ScratchGesture(started: now, timing: timing, minimumContacts: minimum) : nil
        mayJoinScratch = contacts < minimum
        queue = QueueGesture(startedAt: now)
    }

    public mutating func claimHold(at point: CGPoint) -> Bool {
        guard discardAtTouchDown == nil, scratch == nil || scratch?.phase == .undecided,
              !queue.claimed, hypot(point.x, point.y) < ComposerSwipe.minimumTravel else { return false }
        holdClaimed = true
        return true
    }

    public mutating func contactsRemaining(_ count: Int) -> [PadAction] {
        if count < minimumScratchContacts, scratch?.phase == .scratching { scratch?.cancel() }
        return count < 3 ? [.releaseScratch(id)] : []
    }

    public mutating func move(to point: CGPoint, contacts: Int, now: TimeInterval) -> [PadAction] {
        guard !holdClaimed, discardAtTouchDown == nil else { return [] }
        if mayJoinScratch {
            if (abs(point.y) >= ComposerSwipe.minimumTravel && abs(point.y) >= abs(point.x)) || queue.claimed {
                mayJoinScratch = false
            } else if contacts >= minimumScratchContacts {
                scratchOrigin = point
                scratch = ScratchGesture(started: now, timing: timing, minimumContacts: minimumScratchContacts)
                mayJoinScratch = false
            }
        }
        if scratch != nil {
            let undecided = scratch?.phase == .undecided
            let complete = scratch?.move(x: point.x - scratchOrigin.x, y: point.y - scratchOrigin.y,
                                         touches: contacts, now: now) == true
            if complete, let direction = scratch?.recognizedDirection {
                return [.completeScratch(id, contacts: contacts, direction: direction)]
            }
            if undecided, scratch?.phase == .scratching { return [.beginScratch(id)] }
        }
        return tick(at: point, contacts: contacts, now: now)
    }

    public var needsQueueTimer: Bool {
        allowsVertical && !holdClaimed && discardAtTouchDown == nil &&
            (scratch == nil || scratch?.phase == .vertical) && queue.claimed && !queue.committed
    }

    public mutating func tick(at point: CGPoint, contacts: Int, now: TimeInterval) -> [PadAction] {
        guard contacts > 0, allowsVertical, !holdClaimed, discardAtTouchDown == nil,
              scratch == nil || scratch?.phase == .vertical else { return [] }
        let committed = queue.update(x: point.x, y: point.y, now: now)
        if committed { return [.queueHold(false), .queue] }
        return [.queueHold(queue.pending)]
    }

    public mutating func finish(at point: CGPoint, now: TimeInterval, cancelled: Bool) -> [PadAction] {
        guard !holdClaimed else { return [] }
        let duration = now - started
        let down = ComposerSwipe.direction(x: point.x, y: point.y, duration: duration, cancelled: cancelled) == .down
        if let discardAtTouchDown {
            return allowsVertical && down ? [.repeatDiscard(discardAtTouchDown)] : []
        }
        var actions: [PadAction] = []
        if let scratch, scratch.phase == .scratching || scratch.phase == .consumed {
            if !scratch.recognized {
                if let duration = scratch.lastWindowDuration {
                    actions.append(.note(String(format: "Last three strokes took %.2f s · aim for %@", duration, timing.label)))
                } else {
                    actions.append(.note("Scratch counted \(scratch.strokes) of \(ScratchGesture.requiredStrokes) strokes"))
                }
            }
            actions += [.releaseScratch(id), .endScratch(id, scratch)]
        } else if allowsVertical {
            let wasPending = queue.pending
            if queue.release(x: point.x, y: point.y, now: now, cancelled: cancelled) {
                actions.append(.steer)
            } else if !queue.claimed, down {
                actions.append(.discard)
            } else if !queue.committed {
                let message: String
                if cancelled { message = "Swipe interrupted · lift all fingers and try again" }
                else if wasPending { message = "Queue hold cancelled" }
                else if abs(point.y) < ComposerSwipe.minimumTravel { message = "Swipe farther before releasing" }
                else if abs(point.x) > abs(point.y) { message = "Swipe more vertically" }
                else if duration > 1 { message = "Swipe and release within one second, or hold for Queue" }
                else { message = "Swipe not recognized · try again" }
                actions.append(.note(message))
            }
        }
        actions.append(.queueReleased)
        return actions
    }
}
