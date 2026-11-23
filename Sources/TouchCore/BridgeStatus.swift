// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct BridgeStatus: Codable,Equatable,Sendable {
    public enum Dictation: String,Codable,Sendable {
        case idle,recording,transcribing,ready,unknown,failed
        /// Once recording stops, the current draft accepts composer commands.
        public var permitsComposerCommands: Bool {
            switch self {
            case .idle,.ready,.failed,.transcribing: true
            case .recording,.unknown: false
            }
        }
    }
    public enum Submission: String,Codable,Sendable { case sent,uncertain }
    public let discardSelected: Bool?
    public let submission: Submission?
    public let composerHasDraft: Bool?
    public let codexForeground: Bool
    public let dictation: Dictation
    public let recordingID: UUID?
    public init(codexForeground: Bool,dictation: Dictation,recordingID: UUID?=nil,submission: Submission?=nil,composerHasDraft: Bool?=nil,discardSelected: Bool?=nil) {
        self.discardSelected=discardSelected
        self.submission=submission;self.composerHasDraft=composerHasDraft
        self.codexForeground=codexForeground;self.dictation=dictation;self.recordingID=recordingID
    }
}

/// Readiness requires two complete idle observations; failed reads never imply completion.
public struct TranscriptionProgress: Sendable {
    public enum Observation { case busy,idle,unavailable,failed }
    public private(set) var state=BridgeStatus.Dictation.idle
    private var idleSamples=0
    public var needsIdleConfirmation: Bool { state == .transcribing && idleSamples == 1 }
    private var readyUntil: Date?
    public init() {}
    public mutating func begin() { state = .transcribing;idleSamples=0;readyUntil=nil }
    public mutating func observe(_ observation: Observation,now: Date = Date()) {
        if state == .failed {
            switch observation {
            case .busy: begin()
            case .idle:
                idleSamples+=1
                if idleSamples>=2 { state = .idle;idleSamples=0 }
            case .failed,.unavailable: idleSamples=0
            }
            return
        }
        guard state == .transcribing else { return }
        switch observation {
        case .busy,.unavailable: idleSamples=0
        case .failed: state = .failed;idleSamples=0
        case .idle:
            idleSamples+=1
            if idleSamples>=2 { state = .ready;readyUntil=now.addingTimeInterval(0.35) }
        }
    }
    public mutating func advance(now: Date = Date()) {
        if state == .ready,let readyUntil,now >= readyUntil {
            state = .idle;self.readyUntil=nil
        }
    }
    public mutating func expire() { if state == .transcribing { state = .unknown } }
}

public enum TouchPresentation {
    public enum Surface { case phone, macActivity }
    public static let steeringShortcutWarning="Set Codex’s Steer prompt shortcut to Control + Option + Shift + S, then try again"
    public static let queueShortcutWarning="Set Codex’s Queue prompt shortcut to Control + Option + Shift + Q, then try again"
    public static let swipeFocusWarning="Bring Codex to the foreground and click the main chat input, then swipe again"
    public static let foregroundWarning="Bring Codex chat forward before holding to dictate."
    public static func isWarning(_ message: String) -> Bool {
        let prefixes=[swipeFocusWarning,queueShortcutWarning,foregroundWarning,"Bring Codex chat forward before discarding.",steeringShortcutWarning,"Add a prompt in the Codex composer","Click the Codex composer",
            "Finish dictation and check Codex","Release the Mac modifier keys before sending","Enable Accessibility for Trackypady Bridge",
            "Open Codex on this Mac","Open the intended Codex chat window",
            "Wait for Codex to finish transcribing","Wait for Codex to finish preparing",
            "Codex dictation is not ready","Release the Mac modifier keys",
            "Previous attempt is unresolved","A Project X recording is already active",
            "Codex already has a recording","Codex dictation is already starting",
            "Recording is still managed by the phone","No draft to discard","Check Codex and clear the unconfirmed send before discarding"]
        return prefixes.contains { message.hasPrefix($0) }
    }
    public static func headline(connected: Bool,phase: DictationHold.Phase = .idle,status: BridgeStatus?,steeringPending: Bool=false, surface: Surface = .phone) -> String {
        guard connected else { return "" }
        if steeringPending { return "Sending\nSteering" }
        if phase == .starting { return "Starting dictation…" }
        if phase == .stopping { return "Transcribing" }
        if status?.dictation == .transcribing { return "Transcribing" }
        if phase == .recording || status?.dictation == .recording { return "Recording" }
        if status?.submission == .sent { return "Prompt\nSent" }
        if surface == .phone, status?.codexForeground == false { return "Bring Codex\nto front" }
        if status?.dictation == .ready { return "Transcript Done" }
        return surface == .macActivity ? "Idle" : "Ready"
    }
    public static func instruction(connected: Bool,phase: DictationHold.Phase = .idle,status: BridgeStatus?,steeringPending: Bool=false, surface: Surface = .phone) -> String {
        guard connected else { return "" }
        switch headline(connected:connected,phase:phase,status:status,steeringPending:steeringPending,surface:surface) {
        case "Sending\nSteering": return "Submitting the current composer"
        case "Prompt\nSent": return ""
        case "Starting dictation…": return "Activating the microphone"
        case "Recording": return "Keep holding or release to stop"
        case "Transcribing": return "Preparing your text in Codex"
        case "Bring Codex\nto front": return ""
        case "Transcript Done": return "Dictation has finished"
        default: return ""
        }
    }
}
