// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct ScratchTiming: Codable, Equatable, Sendable {
    public static let limits = 100...3000
    public static let step = 50
    // Sandra confirmed 0.20–0.90 s on device, 2026-11-18. Change only with her explicit approval.
    public static let fast = ScratchTiming(minimumMS: 200, maximumMS: 900)
    public let minimumMS: Int
    public let maximumMS: Int

    public init(minimumMS: Int, maximumMS: Int) {
        self.minimumMS = min(max(Self.limits.lowerBound, minimumMS), Self.limits.upperBound - Self.step)
        self.maximumMS = min(max(self.minimumMS + Self.step, maximumMS), Self.limits.upperBound)
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(minimumMS: fields.decode(Int.self, forKey: .minimumMS),
                      maximumMS: fields.decode(Int.self, forKey: .maximumMS))
    }

    public var label: String { String(format: "%.2f–%.2f s", Double(minimumMS)/1000, Double(maximumMS)/1000) }
}

/// One pan owns its direction until all contacts lift. Positions are the
/// displacement of UIKit's touch centroid from the start of the pan.
public struct ScratchGesture {
    public static let requiredStrokes = 3

    public static func minimumContacts(allowSingleFinger: Bool) -> Int {
        allowSingleFinger ? 1 : 2
    }
    public enum Phase { case undecided, vertical, scratching, consumed }
    public enum Direction: Sendable { case left, right }
    public private(set) var phase: Phase = .undecided
    public private(set) var strokes = 0
    public let timing: ScratchTiming
    private let minimumContacts: Int
    private static let travel = 20.0
    private static let slope = tan(Double.pi / 6)
    private var pivotTime: TimeInterval
    private var recentStrokeStarts: [TimeInterval] = []
    public private(set) var lastWindowDuration: TimeInterval?
    public var recognized: Bool { recognizedDirection != nil }
    public private(set) var recognizedDirection: Direction?
    private var direction = 1.0
    private var pivot = (x: 0.0, y: 0.0)

    public init(started: TimeInterval, timing: ScratchTiming = .fast, minimumContacts: Int = 2) {
        pivotTime = started
        self.timing = timing
        self.minimumContacts = minimumContacts
    }

    /// True once, when the latest three alternating strokes fit the timing window.
    public mutating func move(x: Double, y: Double, touches: Int, now: TimeInterval) -> Bool {
        guard phase == .undecided || phase == .scratching else { return false }
        guard touches >= minimumContacts else {
            phase = phase == .scratching ? .consumed : .vertical
            return false
        }
        let point = (x: x, y: y)
        if phase == .undecided {
            // Decide from deliberate movement. Early fingertip settling can
            // point diagonally even when the rest of the stroke is horizontal.
            if abs(y) >= ComposerSwipe.minimumTravel, abs(y) >= abs(x) {
                phase = .vertical
                return false
            }
            guard abs(x) >= 10, abs(y) <= abs(x) * Self.slope + 3 else { return false }
            phase = .scratching
            direction = x >= 0 ? 1 : -1
        }
        if strokes > 0 {
            // Keep tracking overshoot until the fingers actually reverse.
            if (x - pivot.x) * direction < 0 {
                pivot = point
                pivotTime = now
            }
        }
        let travel = (x - pivot.x) * direction
        guard travel >= Self.travel else { return false }
        guard abs(y - pivot.y) <= travel * Self.slope + 3 else { return false }
        strokes += 1
        if recentStrokeStarts.count == Self.requiredStrokes { recentStrokeStarts.removeFirst() }
        recentStrokeStarts.append(pivotTime)
        pivot = point
        pivotTime = now
        let strokeDirection: Direction = direction > 0 ? .right : .left
        direction = -direction
        guard recentStrokeStarts.count == Self.requiredStrokes, let start = recentStrokeStarts.first else { return false }
        lastWindowDuration = now - start
        guard now >= start + Double(timing.minimumMS) / 1000, now <= start + Double(timing.maximumMS) / 1000 else { return false }
        recognizedDirection = strokeDirection
        phase = .consumed
        return true
    }

    public mutating func cancel() { phase = .consumed }
}
