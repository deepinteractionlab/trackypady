// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import TouchCore

/// The Studio Eyes skin sheet maps phone events to the Studio motion implementations.
@MainActor
public final class StudioEyesSkin: PhoneSkin {
    let sheet: StudioEyesSheet
    let idle, dictation, sleep: CharacterSettings

    public var background: Color { sheet.background.color }
    public var ink: Color { sheet.ink.color }

    @Published private(set) var send: CharacterSendPreview?
    @Published private(set) var stop: CharacterStopPreview?
    @Published private(set) var draft: DraftPreview?
    @Published private(set) var recordingErrorAt: Date?
    private var gestureExpiry: Task<Void, Never>?
    private var errorExpiry: Task<Void, Never>?

    static var bundledSheetURL: URL {
        guard let url = Bundle.module.url(forResource: "skin", withExtension: "json", subdirectory: "StudioEyesAssets") else {
            preconditionFailure("Missing bundled Studio Eyes skin sheet")
        }
        return url
    }

    public convenience init() {
        do { try self.init(sheetURL: Self.bundledSheetURL) }
        catch { preconditionFailure("Invalid bundled Studio Eyes skin: \(error)") }
    }

    public init(sheetURL: URL) throws {
        let sheet = try StudioEyesSheet(contentsOf: sheetURL)
        func load(_ name: String) throws -> CharacterSettings {
            let data = try Data(contentsOf: sheetURL.deletingLastPathComponent().appendingPathComponent(name))
            return try JSONDecoder().decode(CharacterState.self, from: data).settings
        }
        self.sheet = sheet
        idle = try load(sheet.presets.idle)
        dictation = try load(sheet.presets.dictation)
        sleep = try load(sheet.presets.sleep)
    }

    public func handle(_ event: PhoneSkinEvent) {
        switch event {
        case .steer:
            clearGesture()
            send = CharacterSendPreview(.steer, sleepSettings: sleep)
            finishGesture(after: CharacterSendAction.steer.duration)
        case .queueHoldBegan:
            clearGesture()
            send = .pendingQueue(sleepSettings: sleep)
        case .queueCommitted:
            let now = Date()
            var queue = send
            clearGesture()
            if queue?.isHoldingQueue != true { queue = .pendingQueue(at: now, sleepSettings: sleep) }
            queue?.commitQueue(at: now)
            send = queue
            let action = CharacterSendAction.queue
            finishGesture(after: action.duration - action.flightDuration)
        case .queueHoldEnded:
            if send?.isHoldingQueue == true { clearGesture() }
        case .sendFailed:
            if send != nil { clearGesture() }
        case .stopped(let direction):
            clearGesture()
            stop = CharacterStopPreview(sleepSettings: sleep, direction: direction == .left ? .left : .right)
            finishGesture(after: CharacterStopPreview.duration)
        case .draftInput(let action):
            let previous = draft
            clearGesture()
            let next = DraftPreview(action == .selecting ? .select : .discard, sleep: sleep, following: previous)
            draft = next
            if let duration = next.duration { finishGesture(after: duration) }
        case .draftFailed:
            if draft != nil { clearGesture() }
        case .selectionCleared:
            if draft?.action == .select { clearGesture() }
        case .recordingError:
            errorExpiry?.cancel()
            recordingErrorAt = Date()
            errorExpiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(RecordingErrorMotion.duration)) } catch { return }
                self?.recordingErrorAt = nil
            }
        case .recordingAcknowledged:
            clearRecordingError()
        case .reset:
            clearGesture()
            clearRecordingError()
        }
    }

    private func clearRecordingError() {
        errorExpiry?.cancel()
        recordingErrorAt = nil
    }

    private func clearGesture() {
        gestureExpiry?.cancel()
        send = nil
        stop = nil
        draft = nil
    }

    private func finishGesture(after duration: TimeInterval) {
        gestureExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            self?.clearGesture()
        }
    }

    func animation(recording: Bool) -> EyeAnimation {
        if recordingErrorAt != nil { return .recordingError }
        if recording { return .dictation }
        if let send { return send.action == .steer ? .steer : .queue }
        if let stop { return stop.direction == .left ? .stopLeft : .stopRight }
        if let draft { return draft.action == .select ? .select : .discard }
        return .idle
    }

    public func character(recording: Bool, playing: Bool) -> some View {
        StudioEyesView(skin: self, recording: recording, playing: playing, referenceSize: nil)
    }

    /// Use the live canvas dimensions when embedding the character in a smaller demo region.
    public func character(recording: Bool, playing: Bool, referenceSize: CGSize) -> some View {
        StudioEyesView(skin: self, recording: recording, playing: playing, referenceSize: referenceSize)
    }

}

private struct StudioEyesView: View {
    @ObservedObject var skin: StudioEyesSkin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let recording: Bool
    let playing: Bool
    let referenceSize: CGSize?

    var body: some View {
        let animation = skin.animation(recording: recording)
        let state: CharacterAnimationState = animation == .dictation || animation == .recordingError ? .dictation : .idle
        let settings = state == .dictation ? skin.dictation : skin.idle
        let headroom = max(CharacterSendAction.headroom(for: skin.idle),
                           skin.idle.secondEye.enabled ? CharacterSendAction.headroom(for: skin.idle.linkedSecondEye) : 0)
        GeometryReader { geometry in
            let size = CGSize(width: settings.drawingWidth, height: settings.drawingHeight)
            let layout = skin.sheet.position(for: animation).layout(in: referenceSize ?? geometry.size, drawing: size, headroom: headroom)
            AnimatedCharacterView(state: state, settings: settings, playing: playing, sendPreview: skin.send,
                                  stopPreview: skin.stop, recordingErrorAt: skin.recordingErrorAt, ink: skin.ink)
                .previewingDraft(skin.draft)
                .scaleEffect(layout.scale)
                .id(state)
                .transition(.opacity)
                .position(layout.center)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: state)
    }
}
