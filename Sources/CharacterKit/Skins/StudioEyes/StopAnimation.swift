// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import SwiftUI

public enum StopDirection: Sendable {
    case left, right
}

public struct CharacterStopPreview: Sendable {
    public let start: Date
    let sleepSettings: CharacterSettings?
    static let duration = 0.58

    let direction: StopDirection
    private let leftPeaks: [CGPoint]
    private let rightPeaks: [CGPoint]

    public init(at start: Date = Date(), sleepSettings: CharacterSettings? = nil, direction: StopDirection = .right) {
        self.start = start
        self.sleepSettings = sleepSettings
        self.direction = direction
        // Draw new teeth once per hit so the silhouette stays legible during recoil.
        func peaks(for spacing: Double) -> [CGPoint] {
            WaveformProfile.anchors(cycles: min(5, max(2, 360 / max(24, spacing))),
                                    irregularity: 0.48, seed: Int.random(in: 0...Int.max),
                                    spacingContrast: 0.24)
        }
        let sleep = sleepSettings ?? CharacterSettings()
        leftPeaks = peaks(for: sleep.spacing)
        rightPeaks = peaks(for: sleep.linkedSecondEye.spacing)
    }

    func impact(at elapsed: Double, rightEye: Bool, paired: Bool = true) -> StopImpact? {
        guard elapsed >= 0, elapsed < Self.duration else { return nil }
        // The ripple reaches the farther eye two frames after contact.
        let follows = paired && (direction == .right ? rightEye : !rightEye)
        let time = max(0, elapsed - (follows ? 0.033 : 0))
        let sign = direction == .right ? 1.0 : -1.0
        return StopImpact(displacement: sign * StopImpact.recoil(time), peaks: rightEye ? rightPeaks : leftPeaks)
    }
}

struct StopImpact {
    let displacement: Double
    let peaks: [CGPoint]

    static func recoil(_ time: Double) -> Double {
        let travel = 0.29
        let strike = 0.035
        if time < strike {
            let t = time / strike
            return travel * (1 - pow(1 - t, 2))
        }
        // Hold the far edge for a frame before the zigzag springs back.
        let t = max(0, time - strike - 0.025)
        let settle = 1 - CharacterMotion.ease((time - 0.36) / 0.12)
        return travel * exp(-6.5 * t) * cos(2 * .pi * t / 0.23) * settle
    }
}

struct StopZigzag: Shape {
    let sleep: CharacterSettings
    let impact: StopImpact

    func path(in rect: CGRect) -> Path {
        let height = rect.height * 0.62
        let baseline = WigglyLine(start: CGPoint(x: rect.midX, y: rect.midY - height / 2),
                                  end: CGPoint(x: rect.midX, y: rect.midY + height / 2),
                                  wiggle: sleep.wiggle, spacing: sleep.spacing, width: sleep.thickness,
                                  variation: sleep.variation, seed: sleep.seed)
        var segment = 1
        let points = (0...300).map { index -> CGPoint in
            let u = Double(index) / 300
            let base = baseline.point(at: u)
            while segment < impact.peaks.count - 1 && u > impact.peaks[segment].x { segment += 1 }
            let a = impact.peaks[segment - 1], b = impact.peaks[segment]
            let zigzag = a.y + (b.y - a.y) * (u - a.x) / (b.x - a.x)
            let center = 4 * u * (1 - u)
            // The middle buckles farther than the tips on contact. Keep the
            // stroke width intact by deforming its centerline before inking it.
            let amplitude = 0.145 + 0.18 * abs(impact.displacement)
            let offset = amplitude * zigzag * (0.65 + 0.35 * center)
            let shove = impact.displacement * (0.58 + 0.42 * center)
            return CGPoint(x: base.x + rect.width * shove - height * offset, y: base.y)
        }
        return ribbon(points, width: sleep.thickness, variation: sleep.variation, seed: sleep.seed)
    }
}
