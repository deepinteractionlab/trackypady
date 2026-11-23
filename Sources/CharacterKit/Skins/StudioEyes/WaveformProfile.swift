// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics

/// A repeatable, stylized audio profile with independently sized peaks.
/// No central envelope: strong peaks can occur anywhere along the line.
struct WaveformProfile {
    /// Periodic cosine interpolation has zero slope at the seam, avoiding loop jumps.
    static func sample(_ position: Double, anchors: [CGPoint]) -> Double {
        let t = position - floor(position)
        let right = anchors.firstIndex(where: { $0.x >= t && $0.x > 0 }) ?? anchors.count - 1
        let a = anchors[right - 1], b = anchors[right]
        let progress = (t - a.x) / max(b.x - a.x, 0.00001)
        let blend = (1 - cos(progress * Double.pi)) / 2
        return a.y + (b.y - a.y) * blend
    }

    static func anchors(cycles: Double, irregularity: Double, seed: Int, peakContrast: Double = 0, spacingContrast: Double = 0) -> [CGPoint] {
        let peakCount = max(2, min(20, Int((cycles * 2).rounded())))
        let irregular = min(max(irregularity, 0), 1)
        var state = UInt64(truncatingIfNeeded: seed)
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / 9007199254740992.0
        }
        var amplitudes: [Double] = []
        var gaps: [Double] = []
        for _ in 0..<peakCount {
            amplitudes.append((1 - irregular) + irregular * (0.12 + 0.88 * pow(random(), 0.7)))
            gaps.append((1 - irregular) + irregular * (0.45 + random() * 1.1))
        }
        gaps.append((1 - irregular) + irregular * (0.45 + random() * 1.1))
        let peakPower = 1 + 7 * min(max(peakContrast, 0), 1)
        let spacingStrength = min(max(spacingContrast, 0), 1)
        let maximumGap = max(gaps.max() ?? 1, 0.001)
        gaps = gaps.map { pow($0 / maximumGap, 1 + 3 * spacingStrength) + 0.08 * spacingStrength }
        let total = gaps.reduce(0, +)
        let maximum = max(amplitudes.max() ?? 1, 0.001)
        var points = [CGPoint(x: 0, y: 0)]
        var position = 0.0
        for index in 0..<peakCount {
            position += gaps[index]
            points.append(CGPoint(x: position / total,
                                  y: max(0.02, pow(amplitudes[index] / maximum, peakPower)) * (index.isMultiple(of: 2) ? -1 : 1)))
        }
        points.append(CGPoint(x: 1, y: 0))
        return points
    }
}
