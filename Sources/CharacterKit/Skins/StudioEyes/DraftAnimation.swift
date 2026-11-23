// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import SwiftUI

public struct DraftPreview: Sendable {
    public enum Action: Sendable { case select, discard }
    public let action: Action
    let start: Date
    let sleep: CharacterSettings?
    private let selectionAge: TimeInterval?
    private static let snapDuration = 0.065

    public init(_ action: Action, at start: Date = Date(), sleep: CharacterSettings? = nil,
                following previous: DraftPreview? = nil) {
        self.action = action
        self.start = start
        self.sleep = sleep
        if action == .discard, let previous, previous.action == .select {
            selectionAge = max(0, start.timeIntervalSince(previous.start))
        } else {
            selectionAge = nil
        }
    }

    private var snapDelay: Double { selectionAge.map { max(0, Self.snapDuration - $0) } ?? 0 }
    private static let discardDuration = 0.34
    var duration: Double? { action == .discard ? snapDelay + Self.discardDuration : nil }

    private func selectedBend(at elapsed: Double) -> Double {
        if elapsed < Self.snapDuration {
            return 0.04 + 0.21 * (1 - pow(1 - elapsed / Self.snapDuration, 2))
        }
        let t = (elapsed - Self.snapDuration) / 0.105
        return 0.25 + (DraftPose.restingBend - 0.25) * CharacterMotion.ease(t)
    }

    func sample(_ elapsed: Double) -> DraftPose? {
        guard elapsed >= 0 else { return nil }
        switch action {
        case .select:
            return DraftPose(bend: selectedBend(at: elapsed))
        case .discard:
            // Back-to-back acknowledgements may arrive in one display frame.
            // Finish the visual snap without delaying either composer command.
            let delay = snapDelay
            if let selectionAge, elapsed < delay {
                return DraftPose(bend: selectedBend(at: selectionAge + elapsed))
            }
            let initialBend = selectionAge.map { selectedBend(at: $0 + delay) } ?? DraftPose.restingBend
            let elapsed = elapsed - delay
            let retract = 0.095, burst = 0.135
            if elapsed < retract {
                let t = elapsed / retract
                return DraftPose(bend: initialBend, length: 1 - (0.45 * t + 0.55 * t * t))
            }
            if elapsed < retract + burst {
                return DraftPose(bend: initialBend, length: 0, burst: (elapsed - retract) / burst)
            }
            return elapsed < Self.discardDuration ? DraftPose(bend: initialBend, length: 0) : nil
        }
    }
}

struct DraftPose {
    static let restingBend = 0.18
    var bend: Double
    var length = 1.0
    var burst: Double?
}

struct DraftLid: Shape {
    let sleep: CharacterSettings
    let pose: DraftPose

    func path(in rect: CGRect) -> Path {
        let inset = rect.width * pose.bend * pose.bend
        let curve = WigglyLine(start: CGPoint(x: rect.minX + inset, y: rect.midY),
                               end: CGPoint(x: rect.maxX - inset, y: rect.midY),
                               wiggle: sleep.wiggle, spacing: sleep.spacing, width: sleep.thickness,
                               variation: sleep.variation, seed: sleep.seed, archHeight: -rect.width * pose.bend)
        if pose.length > 0 {
            // Trim the centerline symmetrically. Keep the original curvature and pen width.
            let start = (1 - pose.length) / 2
            let count = max(1, Int(ceil(300 * pose.length)))
            let points = (0...count).map { curve.point(at: start + pose.length * Double($0) / Double(count)) }
            return ribbon(points, width: sleep.thickness, variation: sleep.variation, seed: sleep.seed,
                          range: start...(start + pose.length))
        }
        guard let t = pose.burst else { return Path() }
        let center = curve.point(at: 0.5)
        let travel = 1 - pow(1 - t, 3)
        var burst = Path()
        for (i, angle) in [-1.30, -0.27, 0.84, 2.54, 3.82].enumerated() {
            let reach = rect.width * (i.isMultiple(of: 2) ? 0.17 : 0.12)
            let tip = reach * (0.25 + 0.75 * travel)
            let tail = tip - reach * 0.24 * (1 - t)
            func point(_ r: Double) -> CGPoint {
                CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
            }
            burst.addPath(ribbon([point(tail), point(tip)], width: sleep.thickness * (1 - t),
                                 variation: 0, seed: sleep.seed))
        }
        return burst
    }
}
