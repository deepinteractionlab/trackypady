// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import TouchCore
import TouchLink

private enum BridgePage: String, CaseIterable {
    case connection = "Connection", gestures = "Gestures", haptics = "Haptics"
    case setup = "Setup", activity = "Activity"

    var symbol: String {
        switch self {
        case .connection: "iphone.radiowaves.left.and.right"
        case .gestures: "hand.point.up.left"
        case .haptics: "waveform"
        case .setup: "wrench.and.screwdriver"
        case .activity: "list.bullet.rectangle"
        }
    }
}

struct BridgeWindow: View {
    @ObservedObject var model: BridgeModel
    @State private var page: BridgePage? = .connection
    @State private var reviewShortcuts = false

    var body: some View {
        NavigationSplitView {
            List(BridgePage.allCases, id: \.self, selection: $page) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .listStyle(.sidebar)
            .navigationTitle("Trackypady Bridge")
            .navigationSplitViewColumnWidth(min: 165, ideal: 195, max: 245)
            .safeAreaInset(edge: .bottom) {
                Button { page = .connection } label: {
                    ConnectionStatusView(model: model)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show connection details")
            }
        } detail: {
            let selected = page ?? .connection
            Group {
                switch selected {
                case .connection:
                    ConnectionPage(model: model) { shortcuts in
                        reviewShortcuts = shortcuts
                        page = .setup
                    }
                case .gestures: GesturesPage(model: model)
                case .haptics: HapticMappingEditor(model: model)
                case .setup:
                    SetupPage(model: model, reviewShortcuts: reviewShortcuts)
                        .onDisappear { reviewShortcuts = false }
                case .activity: ActivityPage(model: model)
                }
            }.navigationTitle(selected.rawValue)
        }.frame(minWidth: 720, minHeight: 500)
    }
}

private struct ConnectionStatusView: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(model.phoneConnected ? Color.green : .orange)
                .frame(width: 8, height: 8).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.phoneConnected ? "Connected to " + (model.pairedPhone?.name ?? "iPhone") : "Not connected")
                if model.phoneConnected, let type = model.connectionType {
                    Text("Via " + type).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ConnectionPage: View {
    @ObservedObject var model: BridgeModel
    let showSetup: (_ shortcuts: Bool) -> Void
    @State private var confirmForget = false

    var body: some View {
        let shortcutIssues = BridgeShortcut.allCases.filter { model.shortcutAttentionDetail($0) != nil }
        let bluetoothPermissionWarning = model.bluetoothPermissionWarning
        let hasPermissionWarning = !model.accessibilityAllowed || bluetoothPermissionWarning != nil
        Form {
            Section("Status") {
                ConnectionStatusView(model: model)
            }
            Section("Device paired") {
                if let phone = model.pairedPhone {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(phone.name)
                            Text("Paired on " + phone.pairedAt.formatted(date: .long, time: .omitted))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Forget", role: .destructive) { confirmForget = true }
                    }
                } else if model.listening {
                    Text("None").foregroundStyle(.secondary)
                    if let image = model.qr {
                        HStack(spacing: 20) {
                            Image(nsImage: image).interpolation(.none).resizable()
                                .frame(width: 138, height: 138).padding(10).background(.white, in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel("Mac pairing QR code")
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Scan to pair your iPhone").font(.headline)
                                Text("You’ll need the Trackypady app on your iPhone. Scan this code with your iPhone Camera, then tap the link to get started.")
                                    .foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 8)
                    }
                } else {
                    Text(model.status).foregroundStyle(.secondary)
                }
            }
            if !model.accessibilityAllowed {
                Section("Needs attention") {
                    HStack(spacing: 16) {
                        AttentionLabel(title: "Accessibility permissions", detail: "Permission is off in macOS.")
                        Spacer(minLength: 0)
                        Button("Review Permissions") { showSetup(false) }
                            .fixedSize()
                    }
                }
            }
            if let warning = bluetoothPermissionWarning {
                Section {
                    HStack(spacing: 16) {
                        AttentionLabel(title: "Bluetooth permissions", detail: warning)
                        Spacer(minLength: 0)
                        Button("Review Permissions") { showSetup(false) }
                            .fixedSize()
                            .accessibilityLabel("Review Bluetooth permissions")
                    }
                } header: {
                    if model.accessibilityAllowed { Text("Needs attention") }
                }
            }
            if model.bluetoothPoweredOff {
                Section {
                    HStack(spacing: 16) {
                        AttentionLabel(title: "Bluetooth", detail: "Bluetooth is off. Turn it on to connect your iPhone.")
                        Spacer(minLength: 0)
                        SystemSettingsButton(title: "Open Bluetooth Settings", action: model.openBluetoothSettings)
                    }
                } header: {
                    if !hasPermissionWarning { Text("Needs attention") }
                }
            }
            if model.lastResultIsError {
                Section {
                    HStack(spacing: 16) {
                        Text(model.lastResult)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.accessibilityAllowed {
                            Spacer(minLength: 0)
                            Button("Open Setup") { showSetup(false) }
                                .fixedSize()
                        }
                    }
                } header: {
                    if !hasPermissionWarning && !model.bluetoothPoweredOff { Text("Needs attention") }
                }
            }
            ForEach(shortcutIssues, id: \.self) { command in
                if let detail = model.shortcutAttentionDetail(command) {
                    Section {
                        HStack(spacing: 16) {
                            AttentionLabel(title: "\(command.title) shortcut", detail: detail)
                            Spacer(minLength: 0)
                            Button("Review Shortcuts") { showSetup(true) }
                                .fixedSize()
                                .accessibilityLabel("Review " + command.title + " shortcut")
                        }
                    } header: {
                        if !hasPermissionWarning && !model.bluetoothPoweredOff && !model.lastResultIsError && command == shortcutIssues.first {
                            Text("Needs attention")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                model.refreshSavedShortcuts()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .confirmationDialog("Forget the saved pairing?", isPresented: $confirmForget) {
            Button("Forget Device", role: .destructive, action: model.forgetDevice)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This iPhone will need to scan a new QR code to reconnect.")
        }
    }
}

private struct AttentionIcon: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle")
            .fontWeight(.bold)
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
    }
}

private struct AttentionLabel: View {
    let title: String
    let detail: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            AttentionIcon()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
    }
}

private struct SetupReadyLabel: View {
    let title: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text("Ready")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "checkmark.circle")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("Ready")
    }
}

private struct AccessibilityPermissionView: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        if model.accessibilityAllowed {
            SetupReadyLabel(title: "Accessibility")
        } else {
            HStack(spacing: 16) {
                AttentionLabel(
                    title: "Accessibility",
                    detail: "Permission is off in macOS. Click Open Accessibility Settings, then turn on Trackypady Bridge."
                )
                Spacer(minLength: 0)
                SystemSettingsButton(title: "Open Accessibility Settings", action: model.openAccessibilitySettings)
            }
            .task {
                while !Task.isCancelled && !model.accessibilityAllowed {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    model.refreshAccessibility()
                }
            }
        }
    }
}

private struct BluetoothPermissionView: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        if model.bluetoothAuthorization == .allowedAlways {
            SetupReadyLabel(title: "Bluetooth")
        } else if let warning = model.bluetoothPermissionWarning {
            HStack(spacing: 16) {
                if model.bluetoothAuthorization == .denied {
                    AttentionLabel(
                        title: "Bluetooth",
                        detail: "Permission is off in macOS. Click Open Bluetooth Privacy Settings, then turn on Trackypady Bridge."
                    )
                    Spacer(minLength: 0)
                    SystemSettingsButton(title: "Open Bluetooth Privacy Settings", action: model.openBluetoothPrivacySettings)
                } else {
                    AttentionLabel(title: "Bluetooth", detail: warning)
                }
            }
        } else {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bluetooth")
                    Text("Allow Bluetooth access when macOS asks.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

private struct SystemSettingsButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "arrow.up.right.square")
                    .accessibilityHidden(true)
            }
        }
        .fixedSize()
        .accessibilityHint("Opens macOS System Settings")
    }
}

private struct GesturesPage: View {
    @ObservedObject var model: BridgeModel
    @State private var guideExpanded = false

    private var swipeFingers: String {
        model.phonePreferences.singleFingerSwipesEnabled ? "1+ fingers" : "3 fingers"
    }

    private var stopFingers: String {
        model.phonePreferences.singleFingerSwipesEnabled ? "one or more fingers" : "two or more fingers"
    }

    var body: some View {
        Form {
            Section("Settings") {
                dictationHoldTimer
                Toggle(isOn: $model.dictateAfterStop) {
                    settingLabel("Hold after Stop to dictate",
                                 detail: "Keep three fingers down after the Stop gesture to start dictation.")
                }
                Toggle(isOn: $model.phonePreferences.singleFingerSwipesEnabled) {
                    settingLabel("Allow one-finger swipes",
                                 detail: "Use one finger to send, steer, queue, discard, or stop. When off, start vertical swipes with three fingers and use two or more for Stop.")
                }
            }
            Section {
                Button {
                    guideExpanded.toggle()
                } label: {
                    HStack {
                        Text("Guide").fontWeight(.semibold)
                        Spacer()
                        Image(systemName: guideExpanded ? "chevron.up" : "chevron.down")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(guideExpanded ? "Expanded" : "Collapsed")
                if guideExpanded {
                    gesture("Bring Codex to front", "Three-finger double tap", "Makes Codex the active app on your Mac.", .wake)
                    gesture("Dictate", "Three-finger hold", "Turns on dictation in Codex.", .dictate)
                    gesture("Send/Steer", "Swipe up with \(swipeFingers) and release", "Sends your draft as a new prompt or steers a response in progress.", .steer)
                    gesture("Queue", "Swipe up with \(swipeFingers) and hold", "Queues your draft for Codex to handle after the current response.", .queueSwipe)
                    gesture("Discard Input", "Swipe down twice with \(swipeFingers)", "Selects your draft first, then deletes the selected text.", .discard)
                    gesture("Stop", "With \(stopFingers), slide left, right, left.", "Brings Codex forward and stops the current response in the open chat.", .stop)
                    gesture("Forget Mac", "Six quick taps with one finger", "Tap the iPhone’s main screen to unpair. The Bridge shows a new QR code when it receives the request.", .forgetMac)
                }
            }
        }.formStyle(.grouped)
    }

    private func settingLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var dictationHoldTimer: some View {
        let stops = PhonePreferences.dictationHoldDurations
        let speed = Binding<Double>(
            get: { Double(PhonePreferences.holdSpeedIndex(for: model.phonePreferences.dictationHoldDuration)) },
            set: { model.phonePreferences.dictationHoldDuration = stops[Int($0.rounded())] }
        )
        let duration = model.phonePreferences.dictationHoldDuration.formatted(.number.precision(.fractionLength(2)))
        let lastStop = Double(stops.count - 1)
        let defaultStop = PhonePreferences.holdSpeedIndex(for: PhonePreferences.defaultDictationHoldDuration)
        return HStack(spacing: 16) {
            settingLabel("Dictation hold timer",
                         detail: "Choose how long to hold three fingers before dictation starts.")
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                sliderCaption("\(duration) s", fraction: speed.wrappedValue / lastStop)
                    .monospacedDigit()
                    .accessibilityHidden(true)
                Slider(value: speed, in: 0...lastStop, step: 1) {
                    Text("Dictation hold timer")
                }
                .labelsHidden()
                .accessibilityValue("\(duration) seconds")
                HStack {
                    Text("Fast")
                    Spacer()
                    Text("Slow")
                }
                .overlay {
                    sliderCaption("Default", fraction: Double(defaultStop) / lastStop)
                }
                .foregroundStyle(.secondary)
            }
            .font(.caption)
            .frame(minWidth: 160, idealWidth: 240, maxWidth: 260)
        }
        .padding(.vertical, 3)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func sliderCaption(_ title: String, fraction: Double) -> some View {
        Text(title).hidden()
            .frame(maxWidth: .infinity)
            .overlay {
                GeometryReader { geometry in
                    // The native thumb stops half a thumb-width inside each end of the track.
                    let inset: CGFloat = 10
                    let x = inset + (geometry.size.width - 2 * inset) * fraction
                    Text(title).fixedSize()
                        .position(x: x, y: geometry.size.height / 2)
                }
            }
    }

    private func gesture(_ name: String, _ input: String, _ effect: String, _ drawing: GestureGuideDrawing) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).fontWeight(.semibold)
            Text(effect).font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 2) {
                Text(input).font(.callout).multilineTextAlignment(.center)
                if drawing == .queueSwipe {
                    HStack(spacing: 18) {
                        VStack(spacing: 2) {
                            GestureGuideIllustration(drawing: .queueSwipe)
                            Text("1. Swipe up with \(swipeFingers)")
                        }
                        VStack(spacing: 2) {
                            GestureGuideIllustration(drawing: .queueHold)
                            Text("2. Keep at least 1 finger down")
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: 320)
                } else {
                    GestureGuideIllustration(drawing: drawing)
                        .frame(width: 156, height: 140)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }.padding(.vertical, 3)
    }
}

private struct SetupPage: View {
    @ObservedObject var model: BridgeModel
    let reviewShortcuts: Bool

    private enum ScrollTarget { case shortcuts }
    private struct ShortcutEdit: Identifiable {
        let command: BridgeShortcut
        let original: [String?]
        var id: BridgeShortcut { command }
    }

    @State private var editingShortcut: ShortcutEdit?
    @ScaledMetric(relativeTo: .body) private var shortcutRowHeight = 28.0

    @ViewBuilder private var shortcutConfirmation: some View {
        if let message = model.shortcutError {
            Text(message)
        }
        if let date = model.lastShortcutPush {
            TimelineView(.periodic(from: date, by: 60)) { context in
                let minutes = max(0, Int(context.date.timeIntervalSince(date) / 60))
                let elapsed = switch minutes {
                case 0: "just now"
                case 1..<60: "\(minutes) min ago"
                case 60..<120: "1 hour ago"
                case 120..<1440: "\(minutes / 60) hours ago"
                case 1440..<2880: "1 day ago"
                default: "\(minutes / 1440) days ago"
                }
                Text("Pushed to Codex · \(elapsed)")
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            setupForm
                .task {
                    if reviewShortcuts {
                        proxy.scrollTo(ScrollTarget.shortcuts, anchor: .top)
                    }
                }
        }
    }

    private var setupForm: some View {
        Form {
            Section("Permissions") {
                AccessibilityPermissionView(model: model)
                BluetoothPermissionView(model: model)
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(BridgeShortcut.allCases, id: \.self) { command in
                        if command != BridgeShortcut.allCases.first {
                            Divider()
                        }
                        HStack {
                            if let detail = model.shortcutAttentionDetail(command, includeRepairGuidance: true) {
                                AttentionLabel(title: command.title, detail: detail)
                            } else {
                                SetupReadyLabel(title: command.title)
                            }
                            Spacer()
                            let shortcut = model.shortcutDrafts[command] ?? ""
                            Text(shortcut.isEmpty ? "Unassigned" : shortcut)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .multilineTextAlignment(.trailing)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.background, in: RoundedRectangle(cornerRadius: 5))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(.quaternary)
                                        .allowsHitTesting(false)
                                }
                            Button("Change") {
                                if let original = model.shortcutEditBase(for: command) {
                                    editingShortcut = ShortcutEdit(command: command, original: original)
                                }
                            }
                            .accessibilityLabel("Change " + command.title + " shortcut")
                            .disabled(!model.canEditShortcuts)
                        }
                        .frame(minHeight: shortcutRowHeight)
                    }
                }
            } header: {
                Text("Shortcuts").id(ScrollTarget.shortcuts)
            } footer: {
                VStack(alignment: .trailing, spacing: 6) {
                    shortcutConfirmation
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                    HStack {
                        if model.hasShortcutEdits {
                            Button("Discard changes", action: model.discardShortcutEdits)
                        }
                        Button("Push changes to Codex", action: model.pushCodexShortcuts)
                            .disabled(!model.canEditShortcuts || !model.hasShortcutEdits || model.shortcutEditsConflict)
                    }
                    .controlSize(.regular)
                    .frame(minHeight: shortcutRowHeight)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .formStyle(.grouped)
        .task {
            model.refreshSetupChecks()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                if !model.pendingShortcutRestarts.isEmpty || BridgeShortcut.allCases.contains(where: { !model.isShortcutConfigured($0) }) {
                    model.refreshSavedShortcuts()
                }
            }
        }
        .sheet(item: $editingShortcut) { edit in
            ShortcutRecorder(command: edit.command) { captured in
                model.editShortcut(edit.command, to: captured, basedOn: edit.original)
                editingShortcut = nil
            }
        }
    }
}

private struct ActivityPage: View {
    @ObservedObject var model: BridgeModel
    @State private var confirmReset = false
    @State private var selectedAttempt: UUID?
    var body: some View {
        Form {
            Section("Current") {
                if model.phoneConnected {
                    Text(model.headline.replacingOccurrences(of: "\n", with: " ")).font(.headline)
                    if !model.instruction.isEmpty { Text(model.instruction).foregroundStyle(.secondary) }
                } else {
                    Text("iPhone disconnected").foregroundStyle(.secondary)
                }
            }
            Section("Recent · latest 12 events") {
                if model.events.isEmpty { Text("Bridge activity will appear here.").foregroundStyle(.secondary) }
                ForEach(model.events) { event in
                    if event.requestID != nil || event.stopPath != nil {
                        DisclosureGroup {
                            if let path = event.stopPath {
                                Text(path.detail)
                                if path == .limited { Text("Codex version not verified.").foregroundStyle(.secondary) }
                            }
                            if let id = event.requestID {
                                LabeledContent("Request ID") { Text(id.uuidString).font(.caption.monospaced()).textSelection(.enabled) }
                            }
                        } label: { row(event) }
                    } else { row(event) }
                }
            }
            Section("Troubleshooting") {
                Button("Clear dictation cache") {
                    guard let attempt = model.dictationRecoveryID else { return }
                    selectedAttempt = attempt
                    confirmReset = true
                }
                .disabled(model.dictationRecoveryID == nil)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Section("Installed build") {
                let identity = BuildIdentity()
                LabeledContent("App version", value: identity.version)
                LabeledContent("Build number", value: identity.build)
                LabeledContent("Build channel", value: identity.channel.capitalized)
                LabeledContent("Git revision", value: String(identity.commit.prefix(7)))
                    .textSelection(.enabled)
                LabeledContent("Uncommitted changes", value: identity.modified ? "Yes" : "No")
                Button("Copy build details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(identity.details, forType: .string)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear dictation cache?", isPresented: $confirmReset, presenting: selectedAttempt) { attempt in
            Button("Clear dictation cache") { model.clearFailedDictationAfterManualCheck(attempt) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("If Codex is still recording, stop it first.") }
    }

    private func row(_ event: BridgeEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(event.timestamp, format: .dateTime.hour().minute().second()).monospacedDigit().foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title).fontWeight(.medium)
                Text(event.result).font(.callout).foregroundStyle(event.failed ? Color.orange : .secondary)
            }
        }.padding(.vertical, 2)
    }
}
