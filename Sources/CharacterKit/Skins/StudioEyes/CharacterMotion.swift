// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import SwiftUI

public enum GazeEasing: String, Codable, Sendable {
    case easeInOut, easeOut, linear
    public func value(at progress: Double) -> Double {
        let t = min(1, max(0, progress))
        switch self {
        case .easeInOut: return (1 - cos(t * Double.pi)) / 2
        case .easeOut: return 1 - pow(1 - t, 3)
        case .linear: return t
        }
    }
}

public enum GazeAxis: String, Codable, Sendable { case horizontal, vertical }

public enum CharacterAnimationState: String, Codable, Sendable { case idle, sleep, dictation, thinking }

/// Seconds and points; saved independently with each state's drawing.
public struct CharacterMotionSettings: Codable, Equatable, Sendable {
    public var blinkInterval = 4.2
    public var timingVariation = 0.35
    public var closeDuration = 0.08
    public var closedHold = 0.02
    public var openDuration = 0.13
    public var gazeEasing = GazeEasing.easeInOut
    public var gazeAxis = GazeAxis.horizontal
    public var gazeRange = 8.0
    public var gazeLeftHold = 0.4
    public var gazeRightHold = 0.4
    public var dartDuration = 0.22
    public var rebound = 0.035
    public var breathPeriod = 4.5
    public var breathDistance = 2.5
    public var waveMotion = 0.65
    public var thinkingHold = 1.3
    public var scribbleMovement = 0.8
    public var scribbleSpeed = 0.6 // Legacy smooth-motion setting; retained for project compatibility.
    public var scribbleRedrawRate = 8.0
    public init() {}
    enum CodingKeys: String, CodingKey { case gazeEasing, gazeAxis, gazeLeftHold, gazeRightHold, blinkInterval, timingVariation, closeDuration, closedHold, openDuration, gazeRange, dartDuration, rebound, breathPeriod, breathDistance, waveMotion, thinkingHold, scribbleMovement, scribbleSpeed, scribbleRedrawRate }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blinkInterval = try c.decodeIfPresent(Double.self, forKey: .blinkInterval) ?? blinkInterval
        timingVariation = try c.decodeIfPresent(Double.self, forKey: .timingVariation) ?? timingVariation
        closeDuration = try c.decodeIfPresent(Double.self, forKey: .closeDuration) ?? closeDuration
        closedHold = try c.decodeIfPresent(Double.self, forKey: .closedHold) ?? closedHold
        openDuration = try c.decodeIfPresent(Double.self, forKey: .openDuration) ?? openDuration
        gazeEasing = try c.decodeIfPresent(GazeEasing.self, forKey: .gazeEasing) ?? gazeEasing
        gazeAxis = try c.decodeIfPresent(GazeAxis.self, forKey: .gazeAxis) ?? gazeAxis
        gazeRange = try c.decodeIfPresent(Double.self, forKey: .gazeRange) ?? gazeRange
        gazeLeftHold = try c.decodeIfPresent(Double.self, forKey: .gazeLeftHold) ?? gazeLeftHold
        gazeRightHold = try c.decodeIfPresent(Double.self, forKey: .gazeRightHold) ?? gazeRightHold
        dartDuration = try c.decodeIfPresent(Double.self, forKey: .dartDuration) ?? dartDuration
        rebound = try c.decodeIfPresent(Double.self, forKey: .rebound) ?? rebound
        breathPeriod = try c.decodeIfPresent(Double.self, forKey: .breathPeriod) ?? breathPeriod
        breathDistance = try c.decodeIfPresent(Double.self, forKey: .breathDistance) ?? breathDistance
        waveMotion = try c.decodeIfPresent(Double.self, forKey: .waveMotion) ?? waveMotion
        thinkingHold = try c.decodeIfPresent(Double.self, forKey: .thinkingHold) ?? thinkingHold
        scribbleMovement = try c.decodeIfPresent(Double.self, forKey: .scribbleMovement) ?? scribbleMovement
        scribbleRedrawRate = try c.decodeIfPresent(Double.self, forKey: .scribbleRedrawRate) ?? scribbleRedrawRate
        scribbleSpeed = try c.decodeIfPresent(Double.self, forKey: .scribbleSpeed) ?? scribbleSpeed
    }

}

public enum RecordingErrorMotion {
    public static let duration = 1.0

    static func waveScale(elapsed: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : 1 - CharacterMotion.ease(elapsed / 0.14)
    }
}

struct CharacterPose {
    var waveScale = 1.0
    var draft: DraftPose?
    var stopImpact: StopImpact?
    var showsSendArch = false
    var sendBend = CharacterSendAction.restingBend
    var pupilInFlight = false
    var pupilHeight = 1.0
    var scribbleFrame = 0
    var scribbleMovement = 0.0
    var openness = 1.0
    var gazeX = 0.0
    var gazeY = 0.0
    var sleepY = 0.0
    var waveEnergy = 1.0
    var waveTime = 0.0
    var waveMotion = 0.0
}

/// Pure, deterministic sampling: random geometry never changes from frame to frame.
enum CharacterMotion {
    static func ease(_ x: Double) -> Double {
        let t = min(1, max(0, x)); return t * t * (3 - 2 * t)
    }
    static func dart(_ x: Double, rebound: Double) -> Double {
        let t = min(1, max(0, x))
        if t < 0.72 { return ease(t / 0.72) * (1 + rebound) }
        return 1 + rebound * (1 - ease((t - 0.72) / 0.28))
    }
    // Long, reproducible sequences with varied intervals; no frame-rate dependence.
    static func slot(_ time: Double, duration: Double, variation: Double) -> (Int, Double) {
        let pattern = [0.0, -0.7, 0.8, -0.2, 0.45, -0.9, 0.25, 1.0, -0.4, 0.65, -0.1, -0.6]
        let lengths = pattern.map { max(0.5, duration * (1 + $0 * variation)) }
        var t = max(0, time).truncatingRemainder(dividingBy: lengths.reduce(0, +))
        for i in lengths.indices {
            if t < lengths[i] { return (i, t) }
            t -= lengths[i]
        }
        return (0, 0)
    }
    static func blink(_ time: Double, settings m: CharacterMotionSettings) -> Double {
        let close = max(0.03, m.closeDuration), hold = max(0, m.closedHold), open = max(0.05, m.openDuration)
        let (_, elapsed) = slot(time, duration: max(close + hold + open + 0.7, m.blinkInterval), variation: min(0.6, max(0, m.timingVariation)))
        // A short open lead-in allows the resting design to register after restart.
        let t = elapsed - 0.8
        if t < 0 { return 1 }
        if t < close { return 1 - ease(t / close) }
        if t < close + hold { return 0 }
        if t < close + hold + open { return ease((t - close - hold) / open) }
        return 1
    }
    /// Smooth movement along one axis through the authored resting position.
    static func straightGaze(settings s: CharacterSettings, time: Double) -> CGPoint {
        let m = s.motion
        guard m.gazeRange > 0 else { return .zero }
        let radius = max(0, s.size * 0.44 - min(s.scribbleSize, s.size * 0.8) * 0.55 - s.scribbleWidth - m.scribbleMovement)
        let vertical = m.gazeAxis == .vertical
        let along = vertical ? s.scribbleY : s.scribbleX
        let across = vertical ? s.scribbleX : s.scribbleY
        guard hypot(along, across) <= radius else { return .zero }
        let boundary = sqrt(max(0, radius * radius - across * across))
        let negative = max(-m.gazeRange, -boundary - along)
        let positive = min(m.gazeRange, boundary - along)
        let duration = max(0.01, m.dartDuration)
        let firstHold = max(0, m.gazeLeftHold), secondHold = max(0, m.gazeRightHold)
        func glide(_ a: Double, _ b: Double, _ t: Double) -> Double {
            let blend = m.gazeEasing.value(at: t)
            return a + (b - a) * blend
        }
        let leadIn = duration / 2
        let offset: Double
        if time < leadIn { offset = glide(0, negative, max(0, time) / leadIn) }
        else {
            let cycle = firstHold + duration + secondHold + duration
            let t = (time - leadIn).truncatingRemainder(dividingBy: cycle)
            if t < firstHold { offset = negative }
            else if t < firstHold + duration { offset = glide(negative, positive, (t - firstHold) / duration) }
            else if t < firstHold + duration + secondHold { offset = positive }
            else { offset = glide(positive, negative, (t - firstHold - duration - secondHold) / duration) }
        }
        return vertical ? CGPoint(x: 0, y: offset) : CGPoint(x: offset, y: 0)
    }
    static func sample(state: CharacterAnimationState, settings s: CharacterSettings, time: Double, audioLevel: Double? = nil) -> CharacterPose {
        let m = s.motion
        var p = CharacterPose()
        switch state {
        case .idle:
            p.openness = blink(time, settings: m)
            let gaze = straightGaze(settings: s, time: time)
            p.gazeX = gaze.x; p.gazeY = gaze.y
            // Gaze and held stroke redraws have independent clocks.
            p.scribbleFrame = Int(floor(max(0, time) * min(24, max(0, m.scribbleRedrawRate))))
            p.scribbleMovement = max(0, m.scribbleMovement)
        case .sleep:
            p.sleepY = sin(time * 2 * .pi / max(1, m.breathPeriod)) * m.breathDistance
        case .dictation:
            let demo = 0.5 + 0.3 * sin(time * 2.7) + 0.2 * sin(time * 6.1)
            let level = min(1, max(0, audioLevel ?? demo))
            p.waveEnergy = 1 - m.waveMotion + m.waveMotion * (0.15 + 0.85 * level)
            p.waveTime = time; p.waveMotion = m.waveMotion
        case .thinking:
            let sequence = [0, 1, 4, 3, 6, 7, 8, 5, 2, 1, 4, 0]
            let (index, elapsed) = slot(time, duration: max(0.5, m.thinkingHold), variation: m.timingVariation)
            let selected = min(8, max(0, s.gridCell))
            let a = (selected + sequence[max(0, index - 1)]) % 9
            let b = (selected + sequence[index]) % 9
            let blend = dart(elapsed / max(0.05, m.dartDuration), rebound: m.rebound)
            let size = min(s.gridSize, s.size * 0.88) / 3
            p.gazeX = (Double(a % 3 - selected % 3) + Double(b % 3 - a % 3) * blend) * size
            p.gazeY = (Double(a / 3 - selected / 3) + Double(b / 3 - a / 3) * blend) * size
        }
        return p
    }
}

/// Native SwiftUI renderer shared by the editor and iOS. Pass nil audioLevel for demo energy.
/// Stop offscreen via playing=false; background and Reduce Motion pause automatically.
public struct AnimatedCharacterView: View {
    public var state: CharacterAnimationState
    public var settings: CharacterSettings
    public var ink: Color
    public var playing: Bool
    public var audioLevel: Double?
    public var recordingErrorAt: Date?
    var draftPreview: DraftPreview?
    public var sendPreview: CharacterSendPreview?
    public var stopPreview: CharacterStopPreview?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var origin = Date()
    public init(state: CharacterAnimationState, settings: CharacterSettings = CharacterSettings(), playing: Bool = true, audioLevel: Double? = nil, sendPreview: CharacterSendPreview? = nil, stopPreview: CharacterStopPreview? = nil, recordingErrorAt: Date? = nil, ink: Color = Color(red: 0.15, green: 0.20, blue: 0.19)) {
        self.state = state; self.settings = settings; self.playing = playing; self.audioLevel = audioLevel
        self.sendPreview = sendPreview
        self.ink = ink
        self.recordingErrorAt = recordingErrorAt
        self.stopPreview = stopPreview
    }
    public func previewingDraft(_ preview: DraftPreview?) -> Self {
        var view = self
        view.draftPreview = preview
        return view
    }

    private var active: Bool { playing && !reduceMotion && scenePhase == .active }
    private func pose(at date: Date) -> CharacterPose {
        let time = max(0, date.timeIntervalSince(origin))
        if state == .dictation, let recordingErrorAt {
            var pose = CharacterMotion.sample(state: .dictation, settings: settings, time: time, audioLevel: audioLevel)
            pose.waveScale = RecordingErrorMotion.waveScale(elapsed: date.timeIntervalSince(recordingErrorAt), reduceMotion: !active)
            return pose
        }
        guard active else { return CharacterPose() }
        if state == .idle, let draftPreview, draftPreview.start >= origin,
           let draft = draftPreview.sample(date.timeIntervalSince(draftPreview.start)) {
            return CharacterPose(draft: draft)
        }
        if state == .idle, let stopPreview, stopPreview.start >= origin,
           let impact = stopPreview.impact(at: date.timeIntervalSince(stopPreview.start), rightEye: false, paired: settings.secondEye.enabled) {
            return CharacterPose(stopImpact: impact)
        }
        if state == .idle, let sendPreview, sendPreview.start >= origin {
            return sendPreview.pose(settings: settings, idleTime: time, elapsed: date.timeIntervalSince(sendPreview.start))
        }
        return CharacterMotion.sample(state: state, settings: settings, time: time, audioLevel: audioLevel)
    }

    private func linkedPose(_ pose: CharacterPose, ratio: Double, at date: Date) -> CharacterPose {
        var other = pose
        if pose.stopImpact != nil, let stopPreview {
            other.stopImpact = stopPreview.impact(at: date.timeIntervalSince(stopPreview.start), rightEye: true)
        }
        other.gazeX *= ratio; other.gazeY *= ratio
        other.sleepY *= ratio; other.scribbleMovement *= ratio
        return other
    }
    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !active)) { context in
            let pose = pose(at: context.date)
            let sleep = draftPreview?.sleep ?? stopPreview?.sleepSettings ?? sendPreview?.sleepSettings
            HStack(spacing: max(0, settings.secondEye.gap)) {
                CharacterDrawing(stateID: state.rawValue, settings: settings, pose: pose, sleepSettings: sleep, ink: ink)
                    .frame(width: settings.size, height: settings.size)
                if settings.secondEye.enabled {
                    let other = settings.linkedSecondEye
                    let waveWidth = max(1, min(settings.waveWidth, settings.size * 0.85))
                    let otherWaveWidth = min(other.waveWidth, other.size * 0.85)
                    let waveOffset = (settings.size / 2 + max(0, settings.secondEye.gap) + other.size / 2 + (waveWidth - otherWaveWidth) / 2) / waveWidth
                    CharacterDrawing(stateID: state.rawValue, settings: other, pose: linkedPose(pose, ratio: other.size / settings.size, at: context.date), sleepSettings: sleep?.linkedSecondEye, waveDomainOffset: waveOffset, waveReferenceWidth: waveWidth, waveReferenceHeight: settings.waveHeight, ink: ink)
                        .frame(width: other.size, height: other.size)
                }
            }
        }
        .frame(width: settings.drawingWidth, height: settings.drawingHeight)
        .onChange(of: active) { _ in origin = Date() }
        .onChange(of: state) { _ in origin = Date() }
        .accessibilityLabel("Character: \(state.rawValue)")
    }
}

// Morph the centerline, then rebuild its ribbon so closing does not flatten stroke width.
private func lidPoint(_ angle: Double, rect: CGRect, settings s: CharacterSettings, openness: Double) -> CGPoint {
    let base = WigglyCircle(wiggle: s.wiggle, phase: s.outlinePhase, spacing: s.spacing).point(angle, in: rect)
    let t = (base.x - rect.minX) / max(1, rect.width)
    let f = 360 / max(24, s.spacing)
    let seam = s.wiggle * rect.width * 0.5 * (0.65 * sin(t * 2 * .pi * f + Double(s.seed) * 0.13) + 0.35 * sin(t * 2 * .pi * (2 * f - 1) - Double(s.seed) * 0.07))
    return CGPoint(x: base.x, y: rect.midY + (base.y - rect.midY) * openness + seam * (1 - openness))
}
struct BlinkingOutline: Shape {
    var settings: CharacterSettings
    var openness: Double
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Both ribbons wind the same way: overlap fills as one solid line at closure.
        for half in 0..<2 {
            let points = (0...360).map { lidPoint(Double($0) / 360 * .pi + Double(half) * .pi, rect: rect, settings: settings, openness: openness) }
            path.addPath(ribbon(points, width: settings.thickness, variation: settings.variation, seed: settings.seed))
        }
        return path
    }
}
struct EyeAperture: Shape {
    var settings: CharacterSettings
    var openness: Double
    func path(in rect: CGRect) -> Path {
        guard openness > 0.001 else { return Path() }
        var path = Path()
        path.addLines((0..<720).map { lidPoint(Double($0) / 720 * 2 * .pi, rect: rect, settings: settings, openness: openness) })
        path.closeSubpath()
        return path
    }
}


/// Closed pose uses the Sleep stroke with an animated upward bend.
struct SendLid: Shape {
    let sleep: CharacterSettings
    var bend = CharacterSendAction.restingBend

    func path(in rect: CGRect) -> Path {
        // Draw the tips inward as the bow deepens, like a flexible strip.
        let inset = rect.width * bend * bend
        return WigglyLine(start: CGPoint(x: rect.minX + inset, y: rect.midY),
                   end: CGPoint(x: rect.maxX - inset, y: rect.midY),
                   wiggle: sleep.wiggle, spacing: sleep.spacing, width: sleep.thickness,
                   variation: sleep.variation, seed: sleep.seed, archHeight: rect.width * bend).path(in: rect)
    }
}
