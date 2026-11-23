// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum CharacterSendAction: Sendable {
    case steer, queue

    // QueueGesture begins its cue after 0.2 s of a 3.2 s hold.
    // queue_pending.ahap has three 120 ms pulses per 620 ms loop.
    private static let queueDelay = 0.2
    private static let queueHold = 3.2
    private static let loopDuration = 0.62
    private static let pulseDuration = 0.12
    private static let pulseOffsets = [0.0, 0.25, 0.50]
    private static let queuePulses: [Double] = {
        var starts: [Double] = []
        var loopStart = queueDelay
        while loopStart < queueHold {
            starts += pulseOffsets.map { loopStart + $0 }.filter { $0 < queueHold }
            loopStart += loopDuration
        }
        return starts
    }()

    // Clearance between the top of the eye and the top of the airborne pupil.
    public static func headroom(for settings: CharacterSettings) -> Double {
        let pupilSize = min(settings.scribbleSize, settings.size * 0.8)
        return settings.size * 0.12 + pupilSize * 1.25 + settings.scribbleWidth
    }

    // Arch height as a fraction of the eye width. The lid closes first, then
    // its center whips upward, rebounds once and settles while the pupil flies.
    static let restingBend = 0.19
    func bend(at elapsed: Double) -> Double {
        let t = elapsed - liftStart
        if t < 0.145 { return 0.06 + 0.28 * CharacterMotion.ease(t / 0.145) }
        if t < 0.24 { return 0.34 - 0.20 * CharacterMotion.ease((t - 0.145) / 0.095) }
        return 0.14 + (Self.restingBend - 0.14) * CharacterMotion.ease((t - 0.24) / 0.095)
    }

    var liftStart: Double { self == .queue ? Self.queueDelay : 0.055 }
    var flightDuration: Double { self == .steer ? liftStart + 0.245 : Self.queueHold }
    var returnDuration: Double { self == .steer ? 0.245 : 0.42 }
    // Each impact retains about half the incoming speed. With constant gravity,
    // airtime scales with speed and rebound height scales with speed squared.
    private static let reboundSpeeds = [0.56, 0.29]
    private static let impactTime = 0.045
    var reboundDuration: Double {
        guard self == .steer else { return 0 }
        return Self.reboundSpeeds.reduce(0) { $0 + Self.impactTime + 2 * returnDuration * $1 }
    }
    public var duration: Double { flightDuration + returnDuration + reboundDuration + 0.16 }

    func rebound(at elapsed: Double) -> (altitude: Double, height: Double) {
        var t = elapsed
        for speed in Self.reboundSpeeds {
            if t < Self.impactTime {
                let compression = sin(.pi * max(0, t) / Self.impactTime)
                return (0, 1 - 0.52 * speed * compression)
            }
            t -= Self.impactTime
            let airtime = 2 * returnDuration * speed
            if t < airtime {
                let u = t / airtime
                return (4 * speed * speed * u * (1 - u), 1 + 0.26 * speed * sin(2 * .pi * u))
            }
            t -= airtime
        }
        return (0, 1)
    }

    // The rising half of a ballistic arc: wide spacing at launch, zero speed at the apex.
    private func rise(_ fraction: Double) -> Double {
        let t = min(1, max(0, fraction))
        return t * (2 - t)
    }

    func progress(at time: Double) -> Double {
        if self == .steer { return rise((time - liftStart) / (flightDuration - liftStart)) }
        var traveled = 0.0
        var pulseTime = 0.0
        for start in Self.queuePulses {
            let duration = min(Self.pulseDuration, Self.queueHold - start)
            traveled += duration * rise((time - start) / duration)
            pulseTime += duration
        }
        let fraction = traveled / pulseTime
        // Taper the step heights while leaving enough travel to read the last beats.
        return 0.6 * fraction + 0.4 * rise(fraction)
    }

    // Offset is measured in pupil diameters, positive downward. Multiplying
    // the two scale axes to one preserves the drawn area during deformation.
    func ball(at time: Double) -> (offset: Double, height: Double) {
        if self == .steer {
            let t = time - liftStart
            if t <= 0 {
                let load = CharacterMotion.ease(time / liftStart)
                return (0.24 * load, 1 - 0.30 * load)
            }
            let push = CharacterMotion.ease(t / 0.032)
            let round = CharacterMotion.ease((t - 0.032) / 0.11)
            return (0.24 * (1 - push),
                    0.70 + 0.72 * push - 0.42 * round)
        }

        guard let start = Self.queuePulses.last(where: { $0 <= time }) else { return (0, 1) }
        let span = min(Self.pulseDuration, Self.queueHold - start)
        let u = (time - start) / span
        guard u < 1 else { return (0, 1) }
        // Each beat lifts off, crests and lands on a progressively higher step.
        // Reduce the hop for the final pulse cut short by the Queue commit.
        let strength = span / Self.pulseDuration
        let hop = 4 * u * (1 - u)
        let stretch = sin(2 * .pi * u)
        return (-0.34 * strength * hop, 1 + 0.19 * strength * stretch)
    }

}

/// The trigger and the Idle clock share a time base. Sample the pose at the
/// trigger once in animation time, so flight never recenters a moving pupil.
public struct CharacterSendPreview: Sendable {
    public let action: CharacterSendAction
    public let start: Date

    let sleepSettings: CharacterSettings?
    // A live Queue starts on the first haptic beat and can outlast the
    // Studio timeline if finger movement restarts the stable-hold timer.
    private enum QueueTiming: Sendable {
        case preview, holding, committed(after: TimeInterval)
    }
    private var queueTiming = QueueTiming.preview

    public var isHoldingQueue: Bool {
        if case .holding = queueTiming { return true }
        return false
    }

    public static func pendingQueue(at start: Date = Date(), sleepSettings: CharacterSettings? = nil) -> Self {
        var preview = Self(.queue, at: start, sleepSettings: sleepSettings)
        preview.queueTiming = .holding
        return preview
    }

    public mutating func commitQueue(at date: Date = Date()) {
        guard isHoldingQueue else { return }
        queueTiming = .committed(after: max(0, date.timeIntervalSince(start)))
    }

    public init(_ action: CharacterSendAction, at start: Date = Date(), sleepSettings: CharacterSettings? = nil) {
        self.sleepSettings = sleepSettings
        self.action = action
        self.start = start
    }

    func pose(settings: CharacterSettings, idleTime: Double, elapsed actualElapsed: Double) -> CharacterPose {
        var idle = CharacterMotion.sample(state: .idle, settings: settings, time: idleTime)
        guard actualElapsed >= 0 else { return idle }
        let elapsed: Double
        switch queueTiming {
        case .preview:
            elapsed = actualElapsed
        case .committed(let commit) where actualElapsed >= commit:
            elapsed = action.flightDuration + actualElapsed - commit
        case .holding, .committed:
            elapsed = min(action.flightDuration, action.liftStart + actualElapsed)
        }
        guard elapsed < action.duration else { return idle }
        var launch = CharacterMotion.sample(state: .idle, settings: settings, time: max(0, idleTime - actualElapsed))
        launch.openness = 1
        let diameter = min(settings.scribbleSize, settings.size * 0.8)
        let apex = -settings.size * 0.62 - diameter / 2 - settings.scribbleY
        let landingTime = action.flightDuration + action.returnDuration
        let settledTime = landingTime + action.reboundDuration
        if elapsed >= settledTime {
            // Land exactly at the launch gaze, then hand back to the live Idle clock.
            let settle = CharacterMotion.ease((elapsed - settledTime) / (action.duration - settledTime))
            idle.gazeX = launch.gazeX + settle * (idle.gazeX - launch.gazeX)
            idle.gazeY = launch.gazeY + settle * (idle.gazeY - launch.gazeY)
            idle.openness = 1
            return idle
        }
        if elapsed >= landingTime {
            let rebound = action.rebound(at: elapsed - landingTime)
            launch.gazeY += (apex - launch.gazeY) * rebound.altitude
            launch.pupilHeight = rebound.height
            launch.pupilInFlight = rebound.altitude > 0
            return launch
        }
        if elapsed >= action.flightDuration {
            let t = (elapsed - action.flightDuration) / action.returnDuration
            let descent = action == .steer ? t * t : CharacterMotion.ease(t)
            launch.gazeY = apex + descent * (launch.gazeY - apex)
            launch.pupilInFlight = true
            launch.showsSendArch = t < 0.5
            launch.sendBend = CharacterSendAction.restingBend
            return launch
        }

        let progress = action.progress(at: elapsed)
        let ball = action.ball(at: elapsed)
        launch.pupilHeight = ball.height
        // End with the whole scribble above the eye and keep its launch X.
        launch.gazeY += progress * (apex - launch.gazeY) + diameter * ball.offset
        guard progress > 0 else { return launch }
        launch.showsSendArch = true
        launch.sendBend = action.bend(at: elapsed)
        launch.pupilInFlight = true
        return launch
    }
}
