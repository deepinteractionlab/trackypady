// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import AppKit

struct ShortcutRecorder: View {
    let command: BridgeShortcut
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var message = "Press the keys for your shortcut."

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit " + command.title + " shortcut").font(.headline)
            Text(message)
            Button("Cancel") { dismiss() }
        }
        .padding(24)
        .frame(minWidth: 320)
        .background(ShortcutCapture(command: command, save: save,
            cancel: { dismiss() }, invalid: { message = "Try a shortcut supported by your keyboard layout." }))
    }
}

private struct ShortcutCapture: NSViewRepresentable {
    let command: BridgeShortcut
    let save: (String) -> Void
    let cancel: () -> Void
    let invalid: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.capture = self
        return view
    }
    func updateNSView(_ view: CaptureView, context: Context) { view.capture = self }
    static func dismantleNSView(_ view: CaptureView, coordinator: ()) { view.stop() }

    final class CaptureView: NSView {
        var capture: ShortcutCapture?
        private var monitor: Any?
        private var held: [UInt16] = []
        private var peak: [UInt16] = []

        // Keep side information for modifier-only dictation bindings such as RightAlt.
        private static let modifiers: [UInt16: String] = [
            59:"Ctrl", 62:"RightControl", 58:"Alt", 61:"RightAlt", 56:"Shift", 60:"RightShift",
            55:"Cmd", 54:"RightCommand", 63:"Fn"
        ]

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                guard let self, let window, window.isKeyWindow, event.window === window,
                      let capture else { return event }
                if event.type == .flagsChanged {
                    guard Self.modifiers[event.keyCode] != nil else { return event }
                    if let index = held.firstIndex(of: event.keyCode) { held.remove(at: index) }
                    else { held.append(event.keyCode) }
                    if held.count > peak.count { peak = held }
                    if held.isEmpty {
                        let keys = peak.compactMap { Self.modifiers[$0] }.joined(separator: "+")
                        peak = []
                        if capture.command == .dictate, ShortcutChord(keys) != nil {
                            stop()
                            capture.save(keys)
                        }
                    }
                    return event
                }
                guard !event.isARepeat else { return nil }
                let flags = event.modifierFlags
                let names: [(NSEvent.ModifierFlags, String)] = [
                    (.control,"Ctrl"), (.option,"Alt"), (.shift,"Shift"), (.command,"Cmd")
                ]
                var parts = names.compactMap { flags.contains($0.0) ? $0.1 : nil }
                if held.contains(63) { parts.append("Fn") }
                if event.keyCode == 53 && parts.isEmpty {
                    stop()
                    capture.cancel()
                    return nil
                }
                let key = ShortcutChord.namedKey(for: event.keyCode) ?? event.characters(byApplyingModifiers: [])?.uppercased()
                let text = (parts + [key ?? ""]).joined(separator: "+")
                guard let chord = ShortcutChord(text), (try? chord.keyCode()) == event.keyCode else {
                    peak = []
                    capture.invalid()
                    return nil
                }
                stop()
                capture.save(text)
                return nil
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            held = []
            peak = []
        }
    }
}
