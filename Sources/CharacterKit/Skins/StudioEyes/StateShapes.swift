// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import SwiftUI

func ribbon(_ points: [CGPoint], width: CGFloat, variation: CGFloat, seed: Int, range: ClosedRange<CGFloat> = 0...1) -> Path {
    guard points.count > 1 else { return Path() }
    let v = min(max(variation, 0), 0.9)
    var outside: [CGPoint] = [], inside: [CGPoint] = []
    for i in points.indices {
        let p = points[i]
        let before = points[max(i - 1, 0)], after = points[min(i + 1, points.count - 1)]
        let dx = after.x - before.x, dy = after.y - before.y
        let length = max(hypot(dx, dy), 0.00001)
        let t = range.lowerBound + (range.upperBound - range.lowerBound) * CGFloat(i) / CGFloat(points.count - 1)
        let noise = 0.65 * sin(t * 19 + CGFloat(seed)) + 0.35 * sin(t * 37 + 0.7)
        let half = max(width, 0.1) * (1 + v * noise) / 2
        outside.append(CGPoint(x: p.x + dy / length * half, y: p.y - dx / length * half))
        inside.append(CGPoint(x: p.x - dy / length * half, y: p.y + dx / length * half))
    }
    var p = Path()
    p.addLines(outside + inside.reversed())
    p.closeSubpath()
    for index in [0, points.count - 1] {
        let t = index == 0 ? range.lowerBound : range.upperBound
        let noise = 0.65 * sin(t * 19 + CGFloat(seed)) + 0.35 * sin(t * 37 + 0.7)
        let w = max(width, 0.1) * (1 + v * noise)
        let center = points[index]
        p.addEllipse(in: CGRect(x: center.x - w / 2, y: center.y - w / 2, width: w, height: w))
    }
    return p
}

/// An open line with the same two-scale waviness as the outer outline.
struct WigglyLine: Shape {
    var start: CGPoint
    var end: CGPoint
    var wiggle: Double
    var spacing: Double
    var width: Double
    var variation: Double
    var seed: Int = 42
    var archHeight: Double = 0

    func point(at t: Double) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.001)
        let frequency = 360 / max(spacing, 24)
        let amplitude = min(max(wiggle, 0), 0.15) * length * 0.5
        let angle = t * 2 * Double.pi
        let wave = 0.65 * sin(frequency * angle + Double(seed) * 0.13)
            + 0.35 * sin((2 * frequency - 1) * angle - Double(seed) * 0.07)
        let bend = amplitude * wave - archHeight * 4 * t * (1 - t)
        return CGPoint(x: start.x + dx * t - dy / length * bend,
                       y: start.y + dy * t + dx / length * bend)
    }

    func path(in rect: CGRect) -> Path {
        ribbon((0...300).map { point(at: Double($0) / 300) }, width: width, variation: variation, seed: seed)
    }
}

struct HandDrawnWaveform: Shape {
    var peakContrast: Double
    var spacingContrast: Double
    var irregularity: Double
    var seed: Int
    var height: Double
    var cycles: Double
    var wiggle: Double
    var spacing: Double
    var width: Double
    var variation: Double
    var motionTime: Double = 0
    var motionAmount: Double = 0
    var domainOffset: Double = 0
    var domainScale: Double = 1
    var referenceWidth: Double = 180
    var waveScale: Double = 1
    func path(in rect: CGRect) -> Path {
        let anchors = WaveformProfile.anchors(cycles: cycles, irregularity: irregularity, seed: seed, peakContrast: peakContrast, spacingContrast: spacingContrast)
        // Increasing the sample coordinate shifts the signal LEFT. Both eyes sample
        // the same world-space signal, including the distance hidden by the gap.
        let travel = motionTime * motionAmount * 0.35
        let spacingPoints = 4 + min(max(spacing, 24), 180) * 0.09
        let amplitude = min(max(wiggle, 0), 0.1) * referenceWidth * 0.75
        let points = (0...800).map { step -> CGPoint in
            let t = Double(step) / 800
            let position = domainOffset + t * domainScale + travel
            let main = WaveformProfile.sample(position, anchors: anchors) * height * 0.5
            let phase = position * referenceWidth / spacingPoints
            let wobble = amplitude * (0.65 * sin(phase * 2 * .pi + Double(seed))
                + 0.35 * sin(phase * 3.7 + Double(seed) * 0.13))
            return CGPoint(x: rect.minX + t * rect.width, y: rect.midY + (main + wobble) * waveScale)
        }
        return ribbon(points, width: width, variation: variation, seed: 78)
    }
}

struct CharacterDrawing: View {
    let stateID: String
    let settings: CharacterSettings
    var pose = CharacterPose()
    var sleepSettings: CharacterSettings?
    var waveDomainOffset: Double = 0
    var waveReferenceWidth: Double? = nil
    var waveReferenceHeight: Double? = nil
    var ink: Color
    var body: some View {
        ZStack {
            if let draft = pose.draft {
                DraftLid(sleep: sleepSettings ?? settings, pose: draft)
                    .fill(ink).frame(width: settings.size, height: settings.size)
            } else if let impact = pose.stopImpact {
                openEyeOutline
                StopZigzag(sleep: sleepSettings ?? settings, impact: impact)
                    .fill(ink).frame(width: settings.size, height: settings.size)
            } else if stateID == "sleep" {
                WigglyLine(start: CGPoint(x: 0, y: 40), end: CGPoint(x: settings.size, y: 40),
                            wiggle: settings.wiggle, spacing: settings.spacing, width: settings.thickness,
                            variation: settings.variation, seed: settings.seed)
                    .fill(ink).frame(width: settings.size, height: 80).offset(y: pose.sleepY)
            } else {
                if pose.showsSendArch {
                    sendLid.fill(ink).frame(width: settings.size, height: settings.size)
                } else if pose.openness >= 1 {
                    openEyeOutline
                } else {
                    BlinkingOutline(settings: settings, openness: pose.openness)
                        .fill(ink).frame(width: settings.size, height: settings.size)
                }
                if stateID == "dictation" {
                    HandDrawnWaveform(peakContrast: settings.wavePeakContrast, spacingContrast: settings.waveSpacingContrast, irregularity: settings.waveIrregularity, seed: settings.waveSeed, height: (waveReferenceHeight ?? settings.waveHeight) * pose.waveEnergy, cycles: settings.waveCycles,
                                      wiggle: settings.detailWiggle, spacing: settings.detailSpacing,
                                      width: settings.detailWidth, variation: settings.detailVariation, motionTime: pose.waveTime, motionAmount: pose.waveMotion, domainOffset: waveDomainOffset, domainScale: min(settings.waveWidth, settings.size * 0.85) / max(1, waveReferenceWidth ?? min(settings.waveWidth, settings.size * 0.85)), referenceWidth: waveReferenceWidth ?? min(settings.waveWidth, settings.size * 0.85), waveScale: pose.waveScale)
                        .fill(ink).frame(width: min(settings.waveWidth, settings.size * 0.85), height: settings.waveHeight + 20)
                } else {
                    if stateID == "thinking" { grid }
                    if pose.pupilInFlight {
                        pupil
                    } else {
                        pupil.frame(width: settings.size, height: settings.size)
                            .mask(EyeAperture(settings: settings, openness: pose.openness))
                    }
                }
            }
        }
    }
    private var openEyeOutline: some View {
        WigglyOutline(wiggle: settings.wiggle, phase: settings.outlinePhase, spacing: settings.spacing,
                      lineWidth: settings.thickness, thicknessVariation: settings.variation, seed: UInt64(settings.seed))
            .fill(ink, style: FillStyle(eoFill: true)).frame(width: settings.size, height: settings.size)
    }

    private var sendLid: SendLid {
        SendLid(sleep: sleepSettings ?? settings, bend: pose.sendBend)
    }

    private var pupil: some View {
        ScribbleCircle(amount: Int(settings.amount), seed: UInt64(settings.scribbleSeed), noise: settings.scribbleNoise, redrawFrame: pose.scribbleFrame, movement: pose.scribbleMovement)
            .stroke(ink, style: StrokeStyle(lineWidth: settings.scribbleWidth, lineCap: .round, lineJoin: .round))
            .frame(width: min(settings.scribbleSize, settings.size * 0.8), height: min(settings.scribbleSize, settings.size * 0.8))
            .scaleEffect(x: 1 / pose.pupilHeight, y: pose.pupilHeight)
            .offset(x: settings.scribbleX + cellX + pose.gazeX, y: settings.scribbleY + cellY + pose.gazeY)
    }
    private var gridSize: Double { min(settings.gridSize, settings.size * 0.88) }
    private var cellX: Double { stateID == "thinking" ? Double(max(0, min(settings.gridCell, 8)) % 3 - 1) * gridSize / 3 : 0 }
    private var cellY: Double { stateID == "thinking" ? Double(max(0, min(settings.gridCell, 8)) / 3 - 1) * gridSize / 3 : 0 }
    private var grid: some View {
        ZStack {
            ForEach(1..<3) { index in
                WigglyLine(start: CGPoint(x: gridSize * Double(index) / 3, y: 0),
                            end: CGPoint(x: gridSize * Double(index) / 3, y: gridSize),
                            wiggle: settings.detailWiggle, spacing: settings.detailSpacing,
                            width: settings.detailWidth, variation: settings.detailVariation, seed: 42 + index)
                    .fill(ink)
                WigglyLine(start: CGPoint(x: 0, y: gridSize * Double(index) / 3),
                            end: CGPoint(x: gridSize, y: gridSize * Double(index) / 3),
                            wiggle: settings.detailWiggle, spacing: settings.detailSpacing,
                            width: settings.detailWidth, variation: settings.detailVariation, seed: 50 + index)
                    .fill(ink)
            }
        }.frame(width: gridSize, height: gridSize)
    }
}
