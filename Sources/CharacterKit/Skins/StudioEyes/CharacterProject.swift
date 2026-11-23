// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct CharacterSettings: Codable, Equatable, Sendable {
    public var wiggle = 0.0303
    public var spacing = 98.97
    public var variation = 0.0
    public var seed = 42
    public var thickness = 3.95
    public var size = 216.0
    public var amount = 13.0
    public var scribbleWidth = 2.04
    public var scribbleSize = 36.6
    public var scribbleSeed = 123
    public var scribbleX = -8.5
    public var scribbleY = 42.3
    public var scribbleNoise = 0.924
    public var detailWiggle = 0.0303
    public var detailSpacing = 98.97
    public var detailWidth = 2.4
    public var detailVariation = 0.0
    public var waveWidth = 140.0
    public var waveHeight = 65.0
    public var waveCycles = 3.0
    public var waveIrregularity = 0.85
    public var waveSeed = 2468
    public var wavePeakContrast = 0.5
    public var waveSpacingContrast = 0.4
    public var gridSize = 160.0
    public var gridCell = 4
    public init() {}
    public var secondEye = SecondEyeSettings()
    public var outlinePhase = 0.0
    public var motion = CharacterMotionSettings()
    enum CodingKeys: String, CodingKey { case secondEye, outlinePhase, motion, wiggle, spacing, variation, seed, thickness, size, amount, scribbleWidth, scribbleSize, scribbleSeed, scribbleX, scribbleY, scribbleNoise, detailWiggle, detailSpacing, detailWidth, detailVariation, waveWidth, waveHeight, waveCycles, waveIrregularity, waveSeed, wavePeakContrast, waveSpacingContrast, gridSize, gridCell }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        secondEye = try c.decodeIfPresent(SecondEyeSettings.self, forKey: .secondEye) ?? secondEye
        outlinePhase = try c.decodeIfPresent(Double.self, forKey: .outlinePhase) ?? outlinePhase
        motion = try c.decodeIfPresent(CharacterMotionSettings.self, forKey: .motion) ?? motion
        wiggle = try c.decodeIfPresent(Double.self, forKey: .wiggle) ?? wiggle
        spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? spacing
        variation = try c.decodeIfPresent(Double.self, forKey: .variation) ?? variation
        seed = try c.decodeIfPresent(Int.self, forKey: .seed) ?? seed
        thickness = try c.decodeIfPresent(Double.self, forKey: .thickness) ?? thickness
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? size
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? amount
        scribbleWidth = try c.decodeIfPresent(Double.self, forKey: .scribbleWidth) ?? scribbleWidth
        scribbleSize = try c.decodeIfPresent(Double.self, forKey: .scribbleSize) ?? scribbleSize
        scribbleSeed = try c.decodeIfPresent(Int.self, forKey: .scribbleSeed) ?? scribbleSeed
        scribbleX = try c.decodeIfPresent(Double.self, forKey: .scribbleX) ?? scribbleX
        scribbleY = try c.decodeIfPresent(Double.self, forKey: .scribbleY) ?? scribbleY
        scribbleNoise = try c.decodeIfPresent(Double.self, forKey: .scribbleNoise) ?? scribbleNoise
        detailWiggle = try c.decodeIfPresent(Double.self, forKey: .detailWiggle) ?? detailWiggle
        detailSpacing = try c.decodeIfPresent(Double.self, forKey: .detailSpacing) ?? detailSpacing
        detailWidth = try c.decodeIfPresent(Double.self, forKey: .detailWidth) ?? detailWidth
        detailVariation = try c.decodeIfPresent(Double.self, forKey: .detailVariation) ?? detailVariation
        waveWidth = try c.decodeIfPresent(Double.self, forKey: .waveWidth) ?? waveWidth
        waveHeight = try c.decodeIfPresent(Double.self, forKey: .waveHeight) ?? waveHeight
        waveCycles = try c.decodeIfPresent(Double.self, forKey: .waveCycles) ?? waveCycles
        waveIrregularity = try c.decodeIfPresent(Double.self, forKey: .waveIrregularity) ?? waveIrregularity
        waveSeed = try c.decodeIfPresent(Int.self, forKey: .waveSeed) ?? waveSeed
        wavePeakContrast = try c.decodeIfPresent(Double.self, forKey: .wavePeakContrast) ?? wavePeakContrast
        waveSpacingContrast = try c.decodeIfPresent(Double.self, forKey: .waveSpacingContrast) ?? waveSpacingContrast
        gridSize = try c.decodeIfPresent(Double.self, forKey: .gridSize) ?? gridSize
        gridCell = try c.decodeIfPresent(Int.self, forKey: .gridCell) ?? gridCell
    }

}

public struct CharacterState: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var status: String
    public var settings: CharacterSettings
}

public struct CharacterProject: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var name = "Character static states"
    public var states: [CharacterState]
    static var initial: CharacterProject {
        CharacterProject(states: [
            CharacterState(id: "idle", name: "Idle state", status: "Approved static design", settings: CharacterSettings()),
            CharacterState(id: "sleep", name: "Sleep", status: "Draft — copied from Idle", settings: CharacterSettings()),
            CharacterState(id: "dictation", name: "Dictation", status: "Draft — copied from Idle", settings: CharacterSettings()),
            CharacterState(id: "thinking", name: "Thinking", status: "Draft — copied from Idle", settings: CharacterSettings())
        ])
    }
}

/// Relative overrides: the master drawing remains the single source of truth.
public struct SecondEyeSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var sizeRatio = 0.9
    public var wiggleRatio = 1.15
    public var spacingRatio = 0.9
    public var gap = 28.0
    public var shapeSeed = 271
    public init() {}
}

extension CharacterSettings {
    public var linkedSecondEye: CharacterSettings {
        var eye = self
        let ratio = min(1.3, max(0.5, secondEye.sizeRatio))
        eye.secondEye.enabled = false
        eye.size *= ratio
        eye.wiggle = min(0.1, max(0, wiggle * secondEye.wiggleRatio))
        eye.spacing = min(180, max(24, spacing * secondEye.spacingRatio))
        eye.outlinePhase += Double(secondEye.shapeSeed % 1000) / 1000 * 2 * .pi
        eye.scribbleSize *= ratio
        eye.scribbleX *= ratio; eye.scribbleY *= ratio
        eye.scribbleSeed = (scribbleSeed + secondEye.shapeSeed) % 1_000_000_000
        eye.motion.gazeRange *= ratio
        eye.motion.scribbleMovement *= ratio
        eye.waveWidth *= ratio; eye.waveHeight *= ratio; eye.gridSize *= ratio
        return eye
    }
    public var drawingWidth: Double { secondEye.enabled ? size + linkedSecondEye.size + max(0, secondEye.gap) + 20 : size + 20 }
    public var drawingHeight: Double { max(size, secondEye.enabled ? linkedSecondEye.size : size) + 20 }
}
