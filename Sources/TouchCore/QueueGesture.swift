// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Quick release steers. Once the hold cue begins, early release cancels rather than steering.
public struct QueueGesture {
    public static let intentDelay: TimeInterval=0.2
    public static let holdDuration: TimeInterval=3.2
    private let startedAt: TimeInterval
    private var stableSince: TimeInterval?
    private var anchorX=0.0,anchorY=0.0
    private var finished=false
    public private(set) var committed=false
    public private(set) var claimed=false
    public private(set) var pending=false
    public init(startedAt: TimeInterval) { self.startedAt=startedAt }
    public mutating func update(x: Double,y: Double,now: TimeInterval) -> Bool {
        guard !finished else { return false }
        guard x.isFinite,y.isFinite,now.isFinite,now>=startedAt else { cancel();return false }
        if !claimed {
            guard y <= -ComposerSwipe.minimumTravel,abs(x)<=(-y) else { return false }
            claimed=true;stableSince=now;anchorX=x;anchorY=y
        }
        let distance=hypot(x-anchorX,y-anchorY)
        if distance>12 {
            stableSince=now;anchorX=x;anchorY=y
        }
        // Movement may restart the stable hold but cannot silently end a pending Queue.
        guard y <= -ComposerSwipe.minimumTravel,abs(x)<=(-y) else { stableSince=now;return false }
        guard let stableSince else { return false }
        let duration=now-stableSince
        if duration>=Self.intentDelay { pending=true }
        if duration>=Self.holdDuration { finished=true;committed=true;pending=false;return true }
        return false
    }
    /// Release can only steer or cancel. Queue commits exclusively in update while held.
    public mutating func release(x: Double,y: Double,now: TimeInterval,cancelled: Bool=false) -> Bool {
        defer { finished=true;pending=false }
        guard !finished,!pending,!cancelled else { return false }
        if claimed,let stableSince,now-stableSince>=Self.intentDelay { return false }
        return SteeringSwipe.qualifies(x:x,y:y,duration:now-startedAt)
    }
    public mutating func cancel() { finished=true;pending=false }
}
