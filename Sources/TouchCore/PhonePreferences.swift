// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Mac-managed preferences applied by the phone's gesture and feedback services.
public struct PhonePreferences: Codable, Equatable, Sendable {
    /// Ordered by hold duration, from the fastest trigger to the slowest.
    public static let dictationHoldDurations: [TimeInterval] = [0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60]
    public static let defaultDictationHoldDuration: TimeInterval = 0.45

    public var dictationHoldDuration: TimeInterval
    public var singleFingerSwipesEnabled: Bool
    public var hapticsDisabled: Bool
    public var recordingHapticsEnabled: Bool
    public var useSystemErrorHaptic: Bool

    public init(singleFingerSwipesEnabled: Bool = true, recordingHapticsEnabled: Bool = true,
                useSystemErrorHaptic: Bool = false, hapticsDisabled: Bool = false,
                dictationHoldDuration: TimeInterval = Self.defaultDictationHoldDuration) {
        self.dictationHoldDuration = Self.dictationHoldDurations[Self.holdSpeedIndex(for: dictationHoldDuration)]
        self.singleFingerSwipesEnabled = singleFingerSwipesEnabled
        self.hapticsDisabled = hapticsDisabled
        self.recordingHapticsEnabled = recordingHapticsEnabled
        self.useSystemErrorHaptic = useSystemErrorHaptic
    }

    public static func holdSpeedIndex(for duration: TimeInterval) -> Int {
        dictationHoldDurations.indices.min {
            abs(dictationHoldDurations[$0] - duration) < abs(dictationHoldDurations[$1] - duration)
        } ?? 0
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            singleFingerSwipesEnabled: values.decode(Bool.self, forKey: .singleFingerSwipesEnabled),
            recordingHapticsEnabled: values.decode(Bool.self, forKey: .recordingHapticsEnabled),
            useSystemErrorHaptic: values.decode(Bool.self, forKey: .useSystemErrorHaptic),
            hapticsDisabled: values.decodeIfPresent(Bool.self, forKey: .hapticsDisabled) ?? false,
            dictationHoldDuration: values.decodeIfPresent(TimeInterval.self, forKey: .dictationHoldDuration)
                ?? Self.defaultDictationHoldDuration
        )
    }
}
