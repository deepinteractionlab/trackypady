// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import SwiftUI

// Blend whole-number harmonics so every spacing closes without a seam.
private func wave(_ angle: CGFloat, phase: CGFloat, spacing: CGFloat) -> CGFloat {
    let frequency = 360 / min(max(spacing, 24), 180)
    let low = floor(frequency)
    let blend = frequency - low
    func harmonic(_ n: CGFloat) -> CGFloat {
        0.65 * sin(n * angle + phase)
            + 0.35 * sin((2 * n - 1) * angle - phase)
    }
    return harmonic(low) * (1 - blend) + harmonic(low + 1) * blend
}

public struct WigglyCircle: Shape {
    public var wiggle: CGFloat = 0.025
    public var phase: CGFloat = 0
    public var spacing: CGFloat = 72

    public init(wiggle: CGFloat = 0.025, phase: CGFloat = 0, spacing: CGFloat = 72) {
        self.wiggle = wiggle; self.phase = phase; self.spacing = spacing
    }

    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(wiggle, phase) }
        set { wiggle = newValue.first; phase = newValue.second }
    }

    func point(_ angle: CGFloat, in rect: CGRect) -> CGPoint {
        let amount = min(max(wiggle, 0), 0.3)
        let radius = min(rect.width, rect.height) / 2 / (1 + amount)
        let r = radius * (1 + amount * wave(angle, phase: phase, spacing: spacing))
        return CGPoint(x: rect.midX + cos(angle) * r, y: rect.midY + sin(angle) * r)
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        for step in 0..<720 {
            let p = point(CGFloat(step) / 720 * 2 * .pi, in: rect)
            if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }
}

/// Fill this ribbon shape to render an outline with smoothly varying width.
public struct WigglyOutline: Shape {
    public var wiggle: CGFloat = 0.025
    public var phase: CGFloat = 0
    public var spacing: CGFloat = 72
    public var lineWidth: CGFloat = 3
    public var thicknessVariation: CGFloat = 0
    public var seed: UInt64 = 42

    public init(wiggle: CGFloat = 0.025, phase: CGFloat = 0,
                spacing: CGFloat = 72, lineWidth: CGFloat = 3,
                thicknessVariation: CGFloat = 0, seed: UInt64 = 42) {
        self.wiggle = wiggle; self.phase = phase; self.spacing = spacing
        self.lineWidth = lineWidth; self.thicknessVariation = thicknessVariation; self.seed = seed
    }

    public func path(in rect: CGRect) -> Path {
        let circle = WigglyCircle(wiggle: wiggle, phase: phase, spacing: spacing)
        let variation = min(max(thicknessVariation, 0), 0.9)
        // Seeded, periodic noise: smooth random widths, stable across frames.
        var state = seed
        var samples: [CGFloat] = (0..<16).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(Double(state >> 11) / 9007199254740992.0)
        }
        let minimum = samples.min() ?? 0
        let span = max((samples.max() ?? 1) - minimum, 0.000001)
        samples = samples.map { (($0 - minimum) / span) * 2 - 1 }
        var outside = [CGPoint]()
        var inside = [CGPoint]()
        for step in 0..<720 {
            let angle = CGFloat(step) / 720 * 2 * .pi
            let p = circle.point(angle, in: rect)
            let before = circle.point(angle - 0.0001, in: rect)
            let after = circle.point(angle + 0.0001, in: rect)
            let dx = after.x - before.x, dy = after.y - before.y
            let length = max(hypot(dx, dy), 0.000001)
            let nx = dy / length, ny = -dx / length
            let position = CGFloat(step) / 720 * CGFloat(samples.count)
            let index = Int(floor(position))
            let t = position - CGFloat(index)
            let smooth = t * t * (3 - 2 * t)
            let thicknessWave = samples[index] * (1 - smooth)
                + samples[(index + 1) % samples.count] * smooth
            let halfWidth = max(lineWidth, 0) * (1 + variation * thicknessWave) / 2
            outside.append(CGPoint(x: p.x + nx * halfWidth, y: p.y + ny * halfWidth))
            inside.append(CGPoint(x: p.x - nx * halfWidth, y: p.y - ny * halfWidth))
        }
        var path = Path()
        path.addLines(outside); path.closeSubpath()
        path.addLines(Array(inside.reversed())); path.closeSubpath()
        return path
    }
}
