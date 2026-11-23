// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import CharacterKit
import SwiftUI
import TouchCore

/// A simulation driven by the real gesture recognizers and skin, never model.handle.
struct GestureDemoView: View {
    @ObservedObject var model: TouchPhoneModel
    @ObservedObject var skin: StudioEyesSkin
    let done: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var demo: GestureDemoState = {
        var state = GestureDemoState()
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--preview-recording-dots") {
            _ = state.beginRecording(bringForwardIfNeeded: true)
        }
        #endif
        return state
    }()
    @State private var transition: Task<Void, Never>?
    @State private var guideVisible = false
    @State private var progressVisible = false
    @State private var displayedStep = 0
    @State private var manualPageReveal = false
    @State private var pageDirection = 1
    @State private var pageDrag: CGFloat = 0

    private var composerHidden: Bool { demo.phase == .bringToFront || demo.phase == .sending || demo.phase == .thinking || demo.phase == .discarding }
    private var interactive: Bool { demo.phase == .bringToFront || demo.phase == .idle || demo.phase == .recording || demo.hasDraft }
    private var instruction: String {
        switch demo.phase {
        case .bringToFront: "Double tap with three fingers"
        case .idle: "Touch and hold with three fingers"
        case .recording: "Keep holding. Release to finish."
        case .transcribing: ""
        case .draftReady: "Swipe up to send\nSwipe down to select"
        case .draftSelected: "Swipe up to send\nSwipe down to discard"
        case .sending, .thinking: ""
        case .discarding: "Discarded"
        }
    }

    var body: some View {
        GeometryReader { liveCanvas in
            content(referenceSize: liveCanvas.size)
        }
    }

    private func content(referenceSize: CGSize) -> some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 650
            ZStack {
                // Whole demo surface receives gestures, including over the miniature composer.
                ThreeFingerPad(scratchTiming: model.scratchTiming,
                               enabled: scenePhase == .active && interactive,
                               dictationHoldDuration: model.preferences.dictationHoldDuration,
                               singleFingerSwipesEnabled: model.preferences.singleFingerSwipesEnabled,
                               pendingDiscard: { nil }, onTap: revealInstructions, onPage: movePage, onPageDrag: dragPage, onAction: handle)
                    .accessibilityLabel("Demo touch surface")
                    .accessibilityHint(instruction)
                VStack(spacing: 0) {
                    DemoComposer(phase: demo.phase, ink: skin.ink, reduceMotion: reduceMotion)
                        .frame(height: compact ? 94 : 112)
                        .opacity(composerHidden ? 0 : 1)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: composerHidden)
                        .overlay(alignment: .topLeading) {
                            if demo.phase == .sending || demo.phase == .thinking {
                                DemoThinking(ink: skin.ink, reduceMotion: reduceMotion)
                                    .padding(16)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, compact ? 12 : 24)
                    // Keep live-canvas sizing instead of shrinking the eyes to this region.
                    // The region begins below the miniature composer.
                    skin.character(recording: demo.phase == .recording, playing: scenePhase == .active,
                                   referenceSize: referenceSize)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    guide(compact: compact)
                        .offset(y: compact ? 0 : -50)
                        .padding(.bottom, compact ? 10 : 24)
                }
                .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 2) {
                Text("Demo mode")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(alignment: .leading) {
                        Button(action: done) {
                            Image(systemName: "chevron.left").font(.headline)
                                .frame(width: 44, height: 44)
                        }
                        .foregroundStyle(skin.ink)
                        .accessibilityLabel("Back")
                        .padding(.leading, 20)
                    }
                Text("Nothing sent to Codex.")
                    .font(.caption).foregroundStyle(skin.ink.opacity(0.74))
            }
            .padding(.bottom, 16)
        }
        .foregroundStyle(skin.ink)
        .background(skin.background.ignoresSafeArea())
        // This skin has a fixed cream canvas; keep semantic text legible on it
        // even when the device uses Dark Mode. Scope this to the demo only.
        .environment(\.colorScheme, .light)
        .task(id: demo.phase) {
            if manualPageReveal {
                manualPageReveal = false
                revealInstructions()
                return
            }
            guideVisible = false
            progressVisible = false
            guard interactive else { return }
            do {
                try await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, scenePhase == .active else { return }
                // Reappear at the last visible position, then show the step change.
                withAnimation(reduceMotion ? nil : .easeIn(duration: 0.32)) { progressVisible = true }
                try await Task.sleep(for: .seconds(0.32))
                guard !Task.isCancelled, scenePhase == .active else { return }
                if displayedStep != demo.step {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) { displayedStep = demo.step }
                    try await Task.sleep(for: .seconds(0.32))
                }
                guard !Task.isCancelled, scenePhase == .active else { return }
                withAnimation(reduceMotion ? nil : .easeIn(duration: 0.32)) { guideVisible = true }
            } catch { return }
        }
        .onChange(of: scenePhase) {
            if $0 != .active { reset() }
            else { revealInstructions() }
        }
        .onDisappear(perform: reset)
    }

    private func guide(compact: Bool) -> some View {
        VStack(spacing: 12) {
            ZStack {
                VStack(spacing: 12) {
                    Group {
                        if demo.hasDraft {
                            HStack(spacing: 30) {
                                Image(systemName: "arrow.up").font(.system(size: 28, weight: .light))
                                Image(systemName: "arrow.down").font(.system(size: 28, weight: .light))
                            }
                        } else if demo.phase == .bringToFront {
                            GestureGuideIllustration(drawing: .wake)
                                .environment(\.colorScheme, .light)
                        } else if demo.phase == .idle || demo.phase == .recording {
                            GestureGuideIllustration(drawing: .dictate)
                                .environment(\.colorScheme, .light)
                        } else {
                            Image(systemName: demo.phase == .transcribing ? "ellipsis" : "checkmark")
                                .font(.system(size: 28, weight: .light))
                        }
                    }
                    .frame(height: compact ? 65 : 92)
                    .opacity(guideVisible ? 1 : 0)
                    .accessibilityHidden(!guideVisible)
                    Text(instruction)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                        .frame(height: 44)
                        .opacity(guideVisible ? 1 : 0)
                        .accessibilityHidden(!guideVisible)
                }
                .id(demo.step)
                .offset(x: pageDrag)
                .transition(.asymmetric(
                    insertion: .move(edge: pageDirection > 0 ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: pageDirection > 0 ? .leading : .trailing).combined(with: .opacity)))
            }
            .clipped()
            HStack(spacing: 8) {
                ForEach(0..<4) { step in
                    Capsule()
                        .fill(skin.ink.opacity(step <= displayedStep ? 0.85 : 0.16))
                        .frame(width: step == displayedStep ? 20 : 6, height: 6)
                }
            }
            .frame(height: 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Demo progress")
            .accessibilityValue("Step \(displayedStep + 1) of 4")
            .opacity(progressVisible ? 1 : 0)
            .accessibilityHidden(!progressVisible)
            Color.clear.frame(height: 18)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    private func dragPage(_ translation: CGFloat) {
        guard demo.phase == .bringToFront || demo.phase == .idle || demo.hasDraft else { return }
        if translation == 0 {
            withAnimation(reduceMotion ? nil : .interpolatingSpring(stiffness: 220, damping: 16)) { pageDrag = 0 }
            return
        }
        let atEdge = (demo.step == 0 && translation > 0) || (demo.step == 3 && translation < 0)
        // Resist overscroll; releasing springs the existing card back into place.
        pageDrag = reduceMotion ? 0 : max(-75, min(75, translation * (atEdge ? 0.22 : 0.5)))
    }

    private func movePage(_ delta: Int) {
        var next = demo
        guard next.movePage(by: delta) else { return }
        transition?.cancel()
        transition = nil
        model.stopPracticeFeedback()
        skin.handle(.reset)
        if next.phase == .draftSelected { skin.handle(.draftInput(.selecting)) }
        pageDirection = delta
        manualPageReveal = true
        guideVisible = true
        progressVisible = true
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            demo = next
            displayedStep = next.step
        }
    }

    private func revealInstructions() {
        guard scenePhase == .active, interactive else { return }
        // Explicit help request bypasses both the wait and fade-in.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            guideVisible = true
            progressVisible = true
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) { displayedStep = demo.step }
    }

    private func handle(_ action: PadAction) {
        switch action {
        case .wake:
            guard demo.bringToFront() else { return }
            skin.handle(.reset)
            model.playPracticeMoment(.wakeInput)
        case .beginHold:
            let combined = demo.phase == .bringToFront
            guard demo.beginRecording(bringForwardIfNeeded: combined) else { return }
            skin.handle(.reset)
            model.beginPracticeHoldFeedback(combined: combined)
        case .endHold(let cancelled):
            guard demo.phase == .recording else { return }
            model.endPracticeHoldFeedback()
            if demo.releaseRecording(cancelled: cancelled) {
                schedule(after: 0.55) {
                    demo.finishTranscribing()
                    model.playPracticeMoment(.transcriptDone)
                }
            }
        case .steer:
            guard demo.send() else { return }
            skin.handle(.steer)
            model.playPracticeMoment(.steeringSent)
            schedule(after: CharacterSendAction.steer.duration) {
                demo.finishSendingAnimation()
                schedule(after: 1.5) { demo.finishAction() }
            }
        case .discard:
            guard demo.swipeDown() else { return }
            let selecting = demo.phase == .draftSelected
            skin.handle(.draftInput(selecting ? .selecting : .discarding))
            model.playPracticeMoment(selecting ? .draftSelected : .draftDiscarded)
            if !selecting { schedule(after: CharacterSendAction.steer.duration) { demo.finishAction() } }
        default:
            // Queue and scratch are deliberately outside this demo.
            break
        }
    }

    private func schedule(after seconds: Double, perform: @escaping @MainActor () -> Void) {
        transition?.cancel()
        transition = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard !Task.isCancelled, scenePhase == .active else { return }
            perform()
        }
    }
    private func reset() {
        transition?.cancel()
        transition = nil
        guideVisible = false
        progressVisible = false
        pageDrag = 0
        displayedStep = 0
        manualPageReveal = false
        demo.reset()
        skin.handle(.reset)
        model.stopPracticeFeedback()
    }
}

private struct DemoComposer: View {
    let phase: GestureDemoState.Phase
    let ink: Color
    let reduceMotion: Bool
    private var hasText: Bool { phase == .draftReady || phase == .draftSelected }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if phase == .recording {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { time in
                    GeometryReader { geometry in
                        let count = 43
                        HStack(spacing: 0) {
                            ForEach(0..<count, id: \.self) { dot in
                                let sweep = 1 - time.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
                                let distance = abs(Double(dot) / Double(count - 1) - sweep)
                                let wrapped = min(distance, 1 - distance)
                                let pulse = exp(-pow(wrapped / 0.1, 2))
                                Circle().fill(ink.opacity(reduceMotion ? 0.48 : 0.38 + 0.32 * pulse))
                                    .frame(width: 2.5, height: 2.5)
                                    .frame(width: geometry.size.width / Double(count))
                            }
                        }.frame(height: geometry.size.height)
                    }
                }
                .frame(height: 34)
                .accessibilityLabel("Simulated recording")
            } else if phase == .transcribing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(ink)
                    Text("Transcribing…").font(.subheadline)
                }.frame(height: 34)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    if hasText {
                        Text("Let’s explore this idea.")
                            .font(.subheadline)
                            .padding(.horizontal, 3).padding(.vertical, 2)
                            .background(phase == .draftSelected ? Color.accentColor.opacity(0.25) : .clear)
                    } else {
                        TimelineView(.animation(minimumInterval: 0.5, paused: reduceMotion)) { time in
                            Rectangle().fill(ink)
                                .frame(width: 1.5, height: 19)
                                .opacity(reduceMotion || Int(time.date.timeIntervalSinceReferenceDate * 2).isMultiple(of: 2) ? 1 : 0)
                        }
                    }
                    Spacer(minLength: 0)
                }.frame(height: 34, alignment: .topLeading)
            }
            HStack {
                if phase == .recording {
                    Image(systemName: "xmark").font(.caption)
                } else {
                    Image(systemName: "plus").font(.subheadline)
                }
                Spacer()
                if phase == .recording {
                    Image(systemName: "stop.fill").font(.caption)
                } else {
                    Image(systemName: hasText ? "arrow.up" : "mic")
                        .font(.caption.weight(.semibold))
                }
            }
            .opacity(0.65)
            .accessibilityHidden(true)
        }
        .foregroundStyle(ink)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ink.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(ink.opacity(0.14), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Match the reference's quiet moving highlight across a stationary Thinking label.
private struct DemoThinking: View {
    let ink: Color
    let reduceMotion: Bool
    @State private var visible = false
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let sweep = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            Text("Thinking")
                .font(.subheadline)
                .foregroundStyle(LinearGradient(
                    colors: [ink.opacity(0.35), ink.opacity(0.8), ink.opacity(0.35)],
                    startPoint: UnitPoint(x: reduceMotion ? 0 : sweep * 2 - 1, y: 0.5),
                    endPoint: UnitPoint(x: reduceMotion ? 1 : sweep * 2, y: 0.5)))
        }
        .opacity(visible ? 1 : 0)
        .task {
            do { try await Task.sleep(for: .seconds(0.14)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.16)) { visible = true }
        }
    }
}
