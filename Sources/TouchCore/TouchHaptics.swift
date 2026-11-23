// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum HapticCue: String,Codable,CaseIterable,Sendable,Hashable {
    case wake="wake_input_recognized"
    case recordingStart="dictation_recording_start"
    case recording="dictation_recording_inprogress"
    case recordingError="recording_error"
    case steering="three_finger_contact_cue"
    case queuePending="queue_pending"
    case queueComplete="queue_complete"
    case draftSelected="discard_pending"
    case draftDiscarded="discard_complete"
    case stopComplete="stop_complete"
    public var title: String {
        switch self {
        case .wake: "Wake input recognized (WIR)"
        case .recordingStart: "Dictation recording start (DRS)"
        case .recording: "Dictation recording in progress (DRIP)"
        case .recordingError: "Recording error (RE)"
        case .steering: "Three-finger contact (TFC)"
        case .queuePending: "Queue pending (QP)"
        case .queueComplete: "Queue complete (QC)"
        case .draftSelected: "Discard pending (DP)"
        case .draftDiscarded: "Discard complete (DC)"
        case .stopComplete: "Stop complete (SC)"
        }
    }
}

/// Allowlisted playback control carried in the existing authenticated status exchange.
/// A nil cue means stop. No paths, arbitrary AHAPs or Codex actions are accepted.
public struct HapticPreviewCommand: Codable,Sendable,Equatable {
    public let recordingError: Bool?
    public let id: UUID
    public let sessionID: UUID
    public let cue: HapticCue?
    public let loop: Bool
    public let reversed: Bool?
    public init(id: UUID=UUID(),sessionID: UUID,cue: HapticCue?=nil,loop: Bool=false,reversed: Bool=false,recordingError: Bool?=nil) {
        self.recordingError = recordingError
        self.id=id;self.sessionID=sessionID;self.cue=cue;self.loop=loop;self.reversed=reversed
    }
}
public struct HapticPreviewState: Codable,Sendable,Equatable {
    public let enabled: Bool
    public let sessionID: UUID?
    public let lastCommandID: UUID?
    public let message: String
    public let playingCue: HapticCue?
    public let looping: Bool?
    public let reversed: Bool?
    public init(enabled: Bool,sessionID: UUID?=nil,lastCommandID: UUID?=nil,message: String="",playingCue: HapticCue?=nil,looping: Bool=false,reversed: Bool=false) {
        self.enabled=enabled;self.sessionID=sessionID;self.lastCommandID=lastCommandID;self.message=message;self.playingCue=playingCue;self.looping=looping;self.reversed=reversed
    }
}

/// Typed, authenticated Mac-to-phone notification, independent of request receipts.
public struct HapticPreviewPush: Codable,Sendable,Equatable {
    public enum Kind: String,Codable,Sendable { case hapticPreview }
    public let version: Int
    public let kind: Kind
    public let command: HapticPreviewCommand
    public init(command: HapticPreviewCommand) { version=1;kind = .hapticPreview;self.command=command }
}

/// A tap plays once; a recognized hold loops and release/cancellation stops it.
public struct HapticPreviewPress {
    public enum End: Equatable { case none,playOnce,stop }
    public private(set) var active=false
    private var looping=false
    public init() {}
    public mutating func begin() -> Bool {
        guard !active else { return false };active=true;looping=false;return true
    }
    public mutating func beginLoop() -> Bool {
        guard active,!looping else { return false };looping=true;return true
    }
    public mutating func end(cancelled: Bool=false) -> End {
        guard active else { return .none }
        defer { active=false;looping=false }
        if looping { return .stop }
        return cancelled ? .none : .playOnce
    }
}

@MainActor
public protocol HapticDriver: AnyObject {
    var onInterruption: (@MainActor ()->Void)? { get set }
    func play(_ cue: HapticCue,loop: Bool,reversed: Bool,delay: TimeInterval,completion: @escaping @MainActor (Bool)->Void) throws
    func stop()
}

/// Playback identities cancel queued sequence steps as well as active players.
/// Does not control gestures, recording leases or command delivery.
@MainActor
public final class TouchHaptics {
    public var isMuted = false {
        didSet { if isMuted && !oldValue { stop() } }
    }
    private let driver: any HapticDriver
    private var token: UUID?
    public private(set) var currentCue: HapticCue?
    public private(set) var currentReversed=false
    public private(set) var currentMoment: HapticMoment?
    public private(set) var mapping: HapticMapping
    private var currentLoop=false
    private var nextMoment: HapticMoment?
    private var gapBeforeNext: TimeInterval = 0
    public var onFailure: ((Error)->Void)?
    public init(driver: any HapticDriver,mapping: HapticMapping = .defaults) {
        self.driver=driver;self.mapping=mapping
        driver.onInterruption={ [weak self] in self?.stop() }
    }
    public func play(_ cue: HapticCue,loop: Bool=false,reversed: Bool=false,thenLoop next: HapticCue?=nil) {
        playResolved(cue,loop:loop,reversed:reversed) { [weak self] in
            if let next { self?.play(next,loop:true) }
        }
    }
    public func playMoment(_ moment: HapticMoment,loop: Bool=false,thenLoop next: HapticMoment?=nil) {
        playMoment(moment, loop: loop, thenLoop: next, gap: 0)
    }

    private func playMoment(_ moment: HapticMoment, loop: Bool, thenLoop next: HapticMoment?,
                            gap: TimeInterval, delay: TimeInterval = 0) {
        guard !isMuted else { return }
        guard let cue=mapping[moment] else {
            stop()
            if let next { playMoment(next,loop:true) }
            else if loop { currentMoment=moment;currentLoop=true }
            return
        }
        playResolved(cue,loop:loop,reversed:mapping.isReversed(moment),delay:delay) { [weak self] in
            if let next { self?.playMoment(next, loop: true, thenLoop: nil, gap: 0, delay: gap) }
        }
        if currentCue != nil { currentMoment=moment;nextMoment=next;gapBeforeNext=gap }
    }
    public func updateMapping(_ value: HapticMapping) {
        let moment=currentMoment,loop=currentLoop,next=nextMoment
        let changed=moment.map { mapping[$0] != value[$0] || mapping.isReversed($0) != value.isReversed($0) } ?? false
        mapping=value
        if changed,let moment { playMoment(moment,loop:loop,thenLoop:next,gap:gapBeforeNext) }
    }
    private func playResolved(_ cue: HapticCue,loop: Bool,reversed: Bool,delay: TimeInterval=0,completion: @escaping @MainActor ()->Void) {
        guard !isMuted else { return }
        stop()
        let id=UUID();token=id;currentCue=cue;currentLoop=loop;currentReversed=reversed
        do {
            try driver.play(cue,loop:loop,reversed:reversed,delay:delay) { [weak self] success in
                guard let self,self.token == id else { return }
                self.token=nil;self.currentCue=nil;self.currentMoment=nil;self.nextMoment=nil;self.currentReversed=false
                if success { completion() }
            }
        } catch {
            guard token == id else { return }
            stop();onFailure?(error)
        }
    }
    public func stop() {
        token=nil;currentCue=nil;currentMoment=nil;nextMoment=nil;currentLoop=false;currentReversed=false
        driver.stop()
    }
    public func stop(ifPlaying cues: Set<HapticCue>) {
        if let currentCue,cues.contains(currentCue) { stop() }
    }
    public func recordingStarted(combined: Bool, afterStop: Bool = false) {
        if afterStop { playMoment(.recordingStart, loop: false, thenLoop: .recordingOngoing, gap: 0.15) }
        else if combined { playMoment(.recordingOngoing,loop:true) }
        else { playMoment(.recordingStart,thenLoop:.recordingOngoing) }
    }
    public func recordingReleased() {
        if currentMoment == .recordingStart || currentMoment == .recordingOngoing { stop() }
    }
    public func queueHoldChanged(_ pending: Bool) {
        if pending {
            if currentMoment != .queuePending { playMoment(.queuePending,loop:true) }
        } else if currentMoment == .queuePending { stop() }
    }
}
