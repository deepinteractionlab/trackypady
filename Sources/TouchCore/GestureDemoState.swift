// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
/// Local-only demo state. No transport, microphone or Codex commands.
public struct GestureDemoState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case bringToFront, idle, recording, transcribing, draftReady, draftSelected, sending, thinking, discarding
    }
    public enum Completion: String, Sendable { case sent = "Sent", discarded = "Discarded" }
    public private(set) var phase: Phase = .bringToFront
    public private(set) var completion: Completion?
    public init() {}
    public var hasDraft: Bool { phase == .draftReady || phase == .draftSelected }
    public var step: Int {
        switch phase {
        case .bringToFront: 0
        case .idle, .recording: 1
        case .transcribing, .draftReady: 2
        case .draftSelected, .sending, .thinking, .discarding: 3
        }
    }
    /// Browse actionable demo steps without firing a gesture or a Codex command.
    @discardableResult public mutating func movePage(by delta: Int) -> Bool {
        guard phase == .bringToFront || phase == .idle || hasDraft, delta == -1 || delta == 1 else { return false }
        let next = step + delta
        guard (0...3).contains(next) else { return false }
        phase = next == 0 ? .bringToFront : next == 1 ? .idle : next == 2 ? .draftReady : .draftSelected
        completion = nil
        return true
    }
    @discardableResult public mutating func bringToFront() -> Bool {
        guard phase == .bringToFront else { return false }
        completion = nil
        phase = .idle
        return true
    }
    @discardableResult public mutating func beginRecording(bringForwardIfNeeded: Bool = false) -> Bool {
        if phase == .bringToFront && bringForwardIfNeeded { _ = bringToFront() }
        guard phase == .idle else { return false }
        completion = nil
        phase = .recording
        return true
    }
    @discardableResult public mutating func releaseRecording(cancelled: Bool) -> Bool {
        guard phase == .recording else { return false }
        phase = cancelled ? .idle : .transcribing
        return !cancelled
    }
    public mutating func finishTranscribing() {
        guard phase == .transcribing else { return }
        phase = .draftReady
    }
    @discardableResult public mutating func send() -> Bool {
        guard hasDraft else { return false }
        phase = .sending
        return true
    }
    @discardableResult public mutating func swipeDown() -> Bool {
        switch phase {
        case .draftReady: phase = .draftSelected
        case .draftSelected: phase = .discarding
        default: return false
        }
        return true
    }
    public mutating func finishSendingAnimation() {
        guard phase == .sending else { return }
        phase = .thinking
    }
    public mutating func finishAction() {
        switch phase {
        case .sending, .thinking: completion = .sent
        case .discarding: completion = .discarded
        default: return
        }
        phase = .bringToFront
    }
    public mutating func reset() { self = Self() }
}
