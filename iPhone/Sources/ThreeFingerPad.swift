// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import UIKit
import TouchCore

private final class TouchSurfaceView: UIView {
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
}

/// Observe native touch delivery without changing the long-press state machine.
private final class DiagnosticHoldRecognizer: UILongPressGestureRecognizer {
    private var contacts=Set<UITouch>()
    override func touchesBegan(_ touches: Set<UITouch>,with event: UIEvent) {
        contacts.formUnion(touches)
        PhoneTrace.event("raw hold touches began=\(touches.count); active=\(contacts.count)")
        super.touchesBegan(touches,with:event)
    }
    override func touchesEnded(_ touches: Set<UITouch>,with event: UIEvent) {
        contacts.subtract(touches)
        PhoneTrace.event("raw hold touches ended=\(touches.count); remaining=\(contacts.count); state=\(state.rawValue)")
        super.touchesEnded(touches,with:event)
    }
    override func touchesCancelled(_ touches: Set<UITouch>,with event: UIEvent) {
        contacts.subtract(touches)
        PhoneTrace.event("raw hold touches cancelled=\(touches.count); remaining=\(contacts.count); state=\(state.rawValue)")
        super.touchesCancelled(touches,with:event)
    }
    override func reset() {
        PhoneTrace.event("raw hold reset; remaining=\(contacts.count); state=\(state.rawValue)")
        contacts.removeAll();super.reset()
    }
}

/// Snapshot the edit at touch-down, before UIKit decides whether this is a pan.
final class ComposerPanRecognizer: UIPanGestureRecognizer {
    var pendingDiscard: () -> UUID? = { nil }
    var onContactsRemaining: (Int) -> Void = { _ in }
    private var contacts = Set<UITouch>()
    private var trackingContact = false
    private(set) var discardAtTouchDown: UUID?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        contacts.formUnion(touches)
        if !trackingContact {
            trackingContact = true
            discardAtTouchDown = pendingDiscard()
        }
        super.touchesBegan(touches, with: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        contacts.subtract(touches)
        onContactsRemaining(contacts.count)
        super.touchesEnded(touches, with: event)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        onContactsRemaining(0)
        super.touchesCancelled(touches, with: event)
    }
    override func reset() {
        onContactsRemaining(0)
        contacts.removeAll()
        trackingContact = false
        discardAtTouchDown = nil
        super.reset()
    }
}

struct ThreeFingerPad: UIViewRepresentable {
    let scratchTiming: ScratchTiming
    let enabled: Bool
    let dictationHoldDuration: TimeInterval
    let singleFingerSwipesEnabled: Bool
    let pendingDiscard: () -> UUID?
    var onTap: (() -> Void)? = nil
    var onPage: ((Int) -> Void)? = nil
    var onPageDrag: ((CGFloat) -> Void)? = nil
    let onAction: (PadAction) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onAction: onAction) }
    func makeUIView(context: Context) -> UIView {
        let view=TouchSurfaceView(); view.isMultipleTouchEnabled=true
        view.backgroundColor = .clear
        if onTap != nil {
            let helpTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.helpTap))
            helpTap.numberOfTouchesRequired = 1
            helpTap.cancelsTouchesInView = false
            helpTap.delegate = context.coordinator
            context.coordinator.helpTapRecognizer = helpTap
            context.coordinator.onTap = onTap
            view.addGestureRecognizer(helpTap)
        }
        let tap=UITapGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.wake))
        tap.numberOfTouchesRequired=3; tap.numberOfTapsRequired=2
        tap.delegate=context.coordinator;context.coordinator.recognizer=tap; view.addGestureRecognizer(tap)
        let hold=DiagnosticHoldRecognizer(target:context.coordinator,action:#selector(Coordinator.hold))
        hold.numberOfTouchesRequired=3;hold.minimumPressDuration=dictationHoldDuration;hold.allowableMovement=CGFloat(ComposerSwipe.minimumTravel)
        hold.delegate=context.coordinator;context.coordinator.holdRecognizer=hold;view.addGestureRecognizer(hold)
        let pan=ComposerPanRecognizer(target:context.coordinator,action:#selector(Coordinator.swipe))
        pan.onContactsRemaining = { [weak coordinator = context.coordinator] count in
            coordinator?.contactsRemaining(count)
        }
        pan.pendingDiscard=pendingDiscard
        // Accept additional contacts throughout the optional one-or-more mode.
        context.coordinator.singleFingerSwipesEnabled=singleFingerSwipesEnabled
        context.coordinator.onPage = onPage
        context.coordinator.onPageDrag = onPageDrag
        pan.minimumNumberOfTouches=1;pan.maximumNumberOfTouches=Int.max;pan.delegate=context.coordinator
        context.coordinator.panRecognizer=pan;view.addGestureRecognizer(pan)
        view.isAccessibilityElement=true; view.accessibilityLabel="Codex touch surface"
        view.accessibilityHint=accessibilityHint
        return view
    }
    private var accessibilityHint: String {
        "Double tap with three fingers to wake; hold three fingers to dictate and release to stop; " +
        (singleFingerSwipesEnabled ? "start swipes with one or more fingers; " : "start swipes with three fingers; keep at least one down to continue; ") +
        "swipe up and release to send as Steering, or hold to Queue; swipe down to discard; " +
        (singleFingerSwipesEnabled
         ? "make three alternating horizontal strokes with one or more fingers to stop the current response"
         : "make three alternating horizontal strokes with two or more fingers to stop the current response")
    }
    func updateUIView(_ view: UIView,context: Context) {
        context.coordinator.scratchTiming = scratchTiming
        if let hold = context.coordinator.holdRecognizer, hold.minimumPressDuration != dictationHoldDuration {
            hold.minimumPressDuration = dictationHoldDuration
        }
        if context.coordinator.singleFingerSwipesEnabled != singleFingerSwipesEnabled {
            // Cancel an in-progress sequence when the mode changes, never reinterpret it.
            context.coordinator.panRecognizer?.isEnabled=false
            context.coordinator.singleFingerSwipesEnabled=singleFingerSwipesEnabled
        }
        view.accessibilityHint=accessibilityHint
        context.coordinator.panRecognizer?.pendingDiscard=pendingDiscard
        context.coordinator.onAction = onAction
        context.coordinator.onTap = onTap
        context.coordinator.onPage = onPage
        context.coordinator.onPageDrag = onPageDrag
        context.coordinator.helpTapRecognizer?.isEnabled = enabled && onTap != nil
        // Avoid resetting recognizers during receipt/heartbeat-driven SwiftUI updates.
        if context.coordinator.recognizer?.isEnabled != enabled { context.coordinator.recognizer?.isEnabled=enabled }
        if context.coordinator.holdRecognizer?.isEnabled != enabled { context.coordinator.holdRecognizer?.isEnabled=enabled }
        if context.coordinator.panRecognizer?.isEnabled != enabled { context.coordinator.panRecognizer?.isEnabled=enabled }
    }
    @MainActor final class Coordinator: NSObject,UIGestureRecognizerDelegate {
        var onAction: (PadAction) -> Void
        var onTap: (() -> Void)?
        var onPage: ((Int) -> Void)?
        var onPageDrag: ((CGFloat) -> Void)?
        var helpTapRecognizer: UITapGestureRecognizer?
        var recognizer: UITapGestureRecognizer?
        var holdRecognizer: UILongPressGestureRecognizer?
        var panRecognizer: ComposerPanRecognizer?
        var singleFingerSwipesEnabled = true
        var scratchTiming = ScratchTiming.fast
        private var interaction: PadInteraction?
        private var queueTimer: Task<Void, Never>?
        private var holdBegan = false

        init(onAction: @escaping (PadAction) -> Void) { self.onAction = onAction }

        @objc func helpTap(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended { onTap?() }
        }

        func contactsRemaining(_ count: Int) {
            let actions = interaction?.contactsRemaining(count) ?? []
            actions.forEach(onAction)
        }
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            recognizer === panRecognizer || panRecognizer?.pendingDiscard() == nil
        }
        // A pan can begin from fingertip settling before the hold timer fires.
        // Let both observe until movement or the hold claims this contact.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            recognizer === helpTapRecognizer || other === helpTapRecognizer ||
            (recognizer === panRecognizer && other === holdRecognizer) ||
            (recognizer === holdRecognizer && other === panRecognizer)
        }
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            if let pan=recognizer as? UIPanGestureRecognizer,pan === panRecognizer {
                let minimumContacts = onPage != nil ? 1 : ScratchGesture.minimumContacts(allowSingleFinger: singleFingerSwipesEnabled)
                guard pan.numberOfTouches >= minimumContacts, !holdBegan,
                      holdRecognizer?.state != .began, holdRecognizer?.state != .changed else { return false }
                // UIKit starts tracking as soon as its pan threshold is crossed.
                // Check final direction and travel at release, after all contacts settle.
                return true
            }
            return true
        }
        @objc func swipe(_ recognizer: ComposerPanRecognizer) {
            let now = CACurrentMediaTime()
            let point = recognizer.translation(in: recognizer.view)
            switch recognizer.state {
            case .began:
                guard !holdBegan else { return }
                interaction = PadInteraction(contacts: recognizer.numberOfTouches, allowSingleFinger: singleFingerSwipesEnabled,
                                             timing: scratchTiming, discardAtTouchDown: recognizer.discardAtTouchDown, now: now)
                fallthrough
            case .changed:
                onPageDrag?(abs(point.x) > abs(point.y) ? point.x : 0)
                let actions = interaction?.move(to: point, contacts: recognizer.numberOfTouches, now: now) ?? []
                actions.forEach(onAction)
                if interaction?.needsQueueTimer == true, queueTimer == nil { startQueueTimer(recognizer) }
            case .ended, .cancelled, .failed:
                onPageDrag?(0)
                queueTimer?.cancel()
                queueTimer = nil
                // Demo-only horizontal paging. Vertical command arbitration stays unchanged.
                if recognizer.state == .ended, !holdBegan, let onPage,
                   abs(point.x) >= 40, abs(point.x) > abs(point.y) {
                    interaction = nil
                    onPage(point.x < 0 ? 1 : -1)
                    return
                }
                let actions = interaction?.finish(at: point, now: now, cancelled: recognizer.state != .ended) ?? []
                interaction = nil
                actions.forEach(onAction)
            default: break
            }
        }

        private func startQueueTimer(_ pan: UIPanGestureRecognizer) {
            queueTimer = Task { [weak self, weak pan] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    guard let self, let pan, self.interaction?.needsQueueTimer == true,
                          pan.state == .began || pan.state == .changed else { return }
                    let actions = self.interaction?.tick(at: pan.translation(in: pan.view),
                                                         contacts: pan.numberOfTouches, now: CACurrentMediaTime()) ?? []
                    actions.forEach(self.onAction)
                }
            }
        }

        @objc func hold(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                if let pan = panRecognizer, interaction != nil {
                    guard interaction?.claimHold(at: pan.translation(in: pan.view)) == true else { return }
                }
                holdBegan = true
                onAction(.beginHold)
            case .ended, .cancelled, .failed:
                if holdBegan { onAction(.endHold(cancelled: recognizer.state != .ended)) }
                holdBegan = false
            default: break
            }
        }

        @objc func wake(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended { onAction(.wake) }
        }
    }
}
