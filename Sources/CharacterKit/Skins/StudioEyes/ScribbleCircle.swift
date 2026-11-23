// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// A roughly circular tangle of off-center loops and crossing strokes.
/// Seeded geometry can gently deform over time without translating the pupil.
public struct ScribbleCircle: Shape {
    public var amount: Int
    public var seed: UInt64
    public var noise: Double
    public var redrawFrame: Int
    public var movement: Double

    public init(amount: Int = 45, seed: UInt64 = 123, noise: Double = 0.25, redrawFrame: Int = 0, movement: Double = 0) {
        self.amount = amount; self.seed = seed; self.noise = noise
        self.redrawFrame = redrawFrame; self.movement = movement
    }

    public func path(in rect: CGRect) -> Path {
        var state = seed
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / 9007199254740992.0
        }
        let roughness = min(max(noise, 0), 1)
        let scale = min(rect.width, rect.height) * 0.43
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.midX + x * scale, y: rect.midY + y * scale)
        }
        var path = Path()
        for stroke in 0..<max(0, min(amount, 160)) {
            let crossing = random() < 0.22
            let rotation = random() * 2 * Double.pi
            let radius = 0.2 + sqrt(random()) * 0.74
            let eccentricity = 0.58 + random() * 0.4
            let centerAngle = random() * 2 * Double.pi
            let displacement = (1 - radius) * (0.25 + random() * 0.6)
            let cx = cos(centerAngle) * displacement
            let cy = sin(centerAngle) * displacement
            let start = random() * 2 * Double.pi
            let sweep = Double.pi * (1.25 + random() * 1.15)
            let tilt = (random() - 0.5) * 0.24
            // Independent smooth random deviations, not repeating radial waves.
            let knots = (0..<12).map { _ in random() * 2 - 1 }
            func irregularity(_ progress: Double) -> Double {
                let position = progress * Double(knots.count - 1)
                let index = min(Int(position), knots.count - 2)
                let t = position - Double(index)
                let ease = t * t * (3 - 2 * t)
                return knots[index] * (1 - ease) + knots[index + 1] * ease
            }
            // Each held redraw gets reproducible, independent noise per stroke.
            // Base geometry, stroke count, placement, and thickness stay unchanged.
            var redrawSeed = seed &+ UInt64(max(0, redrawFrame)) &* 0x9E3779B97F4A7C15 &+ UInt64(stroke) &* 0xBF58476D1CE4E5B9
            func redrawRandom() -> Double {
                redrawSeed = redrawSeed &* 6364136223846793005 &+ 1442695040888963407
                return Double(redrawSeed >> 11) / 9007199254740992.0
            }
            let phaseX = redrawRandom() * 2 * Double.pi
            let phaseY = redrawRandom() * 2 * Double.pi
            let frequencyX = 2 + redrawRandom() * 3
            let frequencyY = 2 + redrawRandom() * 3
            let amplitude = redrawFrame == 0 ? 0 : max(0, movement) / max(1, scale)
            func transformed(_ x: Double, _ y: Double) -> CGPoint {
                let dx = amplitude * sin(x * frequencyX + y * 1.7 + phaseX)
                let dy = amplitude * sin(y * frequencyY - x * 1.3 + phaseY)
                return point(cx + (x + dx) * cos(rotation) - (y + dy) * sin(rotation),
                             cy + (x + dx) * sin(rotation) + (y + dy) * cos(rotation))
            }
            if crossing {
                let y0 = (random() - 0.5) * radius
                let y1 = (random() - 0.5) * radius
                let bend = (random() * 2 - 1) * (0.25 + roughness * 0.5)
                path.move(to: transformed(-radius * 0.9, y0))
                path.addCurve(to: transformed(radius * 0.9, y1),
                              control1: transformed(-radius * 0.3, bend),
                              control2: transformed(radius * 0.3, -bend))
            } else {
                for step in 0...140 {
                    let progress = Double(step) / 140
                    let angle = start + progress * sweep
                    let drift = tilt * (progress - 0.5)
                    let rr = radius * (1 + roughness * 0.19 * irregularity(progress) + drift)
                    let p = transformed(cos(angle) * rr, sin(angle) * rr * eccentricity)
                    if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
            }
        }
        return path
    }
}
