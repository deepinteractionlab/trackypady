// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum HapticMoment: String,Codable,CaseIterable,Sendable,Hashable {
    case wakeInput,recordingStart,recordingOngoing,transcriptDone,recordingError,steeringSent
    case queuePending,queueComplete,draftSelected,draftDiscarded
    public var title: String {
        switch self {
        case .wakeInput: "CBF input"
        case .recordingStart: "Recording start"
        case .recordingOngoing: "Recording ongoing"
        case .recordingError: "Recording error"
        case .steeringSent: "Sending Steering"
        case .queuePending: "Hold to Queue"
        case .queueComplete: "Queue complete"
        case .draftSelected: "Selecting draft"
        case .draftDiscarded: "Discarding"
        case .transcriptDone: "Transcript Done"
        }
    }
    public var loops: Bool { self == .recordingOngoing || self == .queuePending }
    public var columnTitle: String {
        switch self {
        case .wakeInput: "CBF\ninput"
        case .queuePending: "Hold to\nQueue"
        default: title.split(separator:" ",maxSplits:1).joined(separator:"\n")
        }
    }
}

/// Exactly one bundled pattern, or off, per implemented interaction moment.
public struct HapticMapping: Codable,Sendable,Equatable {
    public private(set) var revision: UUID
    public private(set) var assignments: [HapticMoment:HapticCue]
    public private(set) var reversedMoments: Set<HapticMoment>
    private enum CodingKeys: String,CodingKey { case revision,assignments,reversedMoments }
    public static let defaults=HapticMapping(revision:UUID(uuidString:"EA2F4F23-0F9B-4F6E-9AE0-27E8B9257205")!,assignments:[
        .wakeInput:.wake,.recordingStart:.recordingStart,.recordingOngoing:.recording,
        .recordingError:.recordingError,.queuePending:.queuePending,
        .queueComplete:.queueComplete,.draftDiscarded:.draftDiscarded
    ])
    public init(revision: UUID=UUID(),assignments: [HapticMoment:HapticCue],reversedMoments: Set<HapticMoment>=[]) {
        self.revision=revision;self.assignments=assignments;self.reversedMoments=reversedMoments.intersection(assignments.keys)
    }
    public init(from decoder: any Decoder) throws {
        let data=try decoder.container(keyedBy:CodingKeys.self)
        revision=try data.decode(UUID.self,forKey:.revision)
        assignments=try data.decode([HapticMoment:HapticCue].self,forKey:.assignments)
        reversedMoments=(try data.decodeIfPresent(Set<HapticMoment>.self,forKey:.reversedMoments) ?? []).intersection(assignments.keys)
    }
    public subscript(_ moment: HapticMoment) -> HapticCue? { assignments[moment] }
    public func isReversed(_ moment: HapticMoment) -> Bool { reversedMoments.contains(moment) }
    public mutating func set(_ cue: HapticCue?,reversed: Bool=false,for moment: HapticMoment) {
        let reverse=cue != nil && reversed
        guard assignments[moment] != cue || isReversed(moment) != reverse else { return }
        assignments[moment]=cue
        if reverse { reversedMoments.insert(moment) } else { reversedMoments.remove(moment) }
        revision=UUID()
    }
    public mutating func cycle(_ cue: HapticCue,for moment: HapticMoment) {
        if assignments[moment] != cue { set(cue,for:moment) }
        else if !isReversed(moment) { set(cue,reversed:true,for:moment) }
        else { set(nil,for:moment) }
    }
    public mutating func restoreDefaults() {
        assignments=Self.defaults.assignments;reversedMoments=[];revision=UUID()
    }
}
