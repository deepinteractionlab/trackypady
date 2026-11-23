// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import CharacterKit
import SwiftUI
import UIKit
import SafariServices
import VisionKit
import TouchCore
import TouchLink

// Choose the bundled skin here. The gesture surface and connection model are shared.
private typealias ActivePhoneSkin = StudioEyesSkin

@main
struct TrackypadyApp: App {
    @StateObject private var model: TouchPhoneModel
    @StateObject private var skin: ActivePhoneSkin
    @State private var practicing: Bool = {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("--preview-recording-dots")
        #else
        return false
        #endif
    }()
    @State private var invalidPairingLink = false
    @State private var presentedInfo: PhoneInfoSheet?
    @AppStorage("resumeQRScannerAfterSettings") private var resumeScannerAfterSettings = false

    init() {
        PhoneTrace.event("Phone app launched")
        let skin = ActivePhoneSkin()
        _skin = StateObject(wrappedValue: skin)
        _model = StateObject(wrappedValue: TouchPhoneModel(present: skin.handle))
    }

    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            ZStack {
                skin.background.ignoresSafeArea()
                if model.acceptsGestures {
                    ThreeFingerPad(scratchTiming: model.scratchTiming,
                                   enabled: model.acceptsGestures && phase == .active && !model.scanning,
                                   dictationHoldDuration: model.preferences.dictationHoldDuration,
                                   singleFingerSwipesEnabled: model.preferences.singleFingerSwipesEnabled,
                                   pendingDiscard: { model.discardRequestID }, onAction: model.handle)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                    skin.character(recording: model.bridgeStatus?.dictation == .recording && model.recordingPhase != .stopping,
                                   playing: !model.scanning)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else if practicing && !model.showsConnectionProgress {
                    GestureDemoView(model: model, skin: skin, done: { practicing = false })
                } else {
                    VStack(spacing: 28) {
                        if model.showsConnectionProgress {
                            VStack(spacing: 12) {
                                ProgressView().tint(skin.ink)
                                Text("Connecting to Mac…")
                                    .font(.subheadline)
                            }
                            .accessibilityElement(children: .combine)
                            if model.reconnectNeedsHelp {
                                Text("Keep Trackypady Bridge open on your Mac. Your iPhone will keep trying.")
                                    .font(.footnote).multilineTextAlignment(.center)
                                Button("Use a new pairing code", action: model.scan)
                                    .font(.footnote)
                            }
                        }
                        if !model.showsConnectionProgress {
                            if model.macForgotPairing { Text("Your Mac forgot this iPhone.").font(.subheadline) }
                            if model.hasPendingForget {
                                Text("Waiting to notify your previous Mac. Open Trackypady Bridge nearby.")
                                    .font(.subheadline).multilineTextAlignment(.center)
                            }
                            VStack(spacing: 8) {
                                Button(action: model.scan) {
                                    Label("Scan to pair", systemImage: "qrcode.viewfinder")
                                }
                                .buttonStyle(OnboardingButtonStyle(filled: true, ink: skin.ink, paper: skin.background))
                                .accessibilityHint("Find the code in Trackypady Bridge, under Connection, then Device Paired.")
                                .onAppear { PhoneTrace.event("Scan QR Code button visible") }
                                Text("Mac bridge required.")
                                    .font(.caption)
                                    .foregroundStyle(skin.ink.opacity(0.74))
                                    .multilineTextAlignment(.center)
                            }
                            let repository = URL(string: "https://github.com/deepinteractionlab/trackypady")!
                            VStack(spacing: 8) {
                                Text("Don’t have the bridge?")
                                    .font(.subheadline.weight(.medium))
                                Link(destination: repository) {
                                    VStack(spacing: 4) {
                                        Text("Get the .DMG on GitHub")
                                        Text(verbatim: repository.formatted(.url.scheme(.never)))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.center)
                                    }
                                }
                            }.font(.footnote)
                        }
                    }
                    .foregroundStyle(skin.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        VStack(spacing: -8) {
                            Image("TrackypadyLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 160, height: 160)
                                .accessibilityHidden(true)
                                .overlay(alignment: .trailing) {
                                    if !model.showsConnectionProgress {
                                        infoMenu.offset(x: 52)
                                    }
                                }
                            Text("Trackypady")
                                .font(.title2.weight(.medium))
                                .accessibilityAddTraits(.isHeader)
                        }
                        .foregroundStyle(skin.ink)
                        .padding(.top, 12)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if !model.showsConnectionProgress {
                            phoneFooter
                        }
                    }
                }
            }
            .sheet(item: $presentedInfo) { info in
                switch info {
                case .help:
                    PhoneInfoBrowser(url: Self.supportURL)
                        .ignoresSafeArea(edges: .bottom)
                case .privacy:
                    PhoneInfoBrowser(url: Self.privacyURL)
                        .ignoresSafeArea(edges: .bottom)
                case .version:
                    NavigationStack {
                        Form {
                            let identity = BuildIdentity()
                            LabeledContent("App version", value: identity.version)
                            LabeledContent("Build number", value: identity.build)
                            LabeledContent("Build channel", value: identity.channel.capitalized)
                            LabeledContent("Git revision", value: String(identity.commit.prefix(7)))
                                .textSelection(.enabled)
                            LabeledContent("Uncommitted changes", value: identity.modified ? "Yes" : "No")
                            Button("Copy details") { UIPasteboard.general.string = identity.details }
                        }
                        .navigationTitle("Version")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { presentedInfo = nil } } }
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture(count: 6).onEnded {
                guard phase == .active, !model.scanning, !practicing else { return }
                model.forgetMac()
            })
            .onChange(of: model.acceptsGestures) { ready in if ready { practicing = false } }
            .alert("Open Trackypady settings", isPresented: $model.showWiFiSettingsHelp) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("On your iPhone, go to Settings → Apps → Trackypady and turn on Local Network.")
            }
            .statusBarHidden()
            .alert("Pairing", isPresented: Binding(get: { model.pairingAlert != nil },
                                                  set: { if !$0 { model.pairingAlert = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.pairingAlert ?? "") }
            .persistentSystemOverlays(.hidden)
            .task {
                if phase == .active { activate() }
            }
            .onOpenURL(perform: openPairingLink)
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { openPairingLink(url) }
            }
            .alert("Pairing link unavailable", isPresented: $invalidPairingLink) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Scan the QR code currently displayed in Trackypady Bridge on your Mac.")
            }
            .sheet(isPresented: $model.scanning, onDismiss: model.scannerDismissed) {
                NavigationStack {
                    VStack(spacing:0) {
                        if model.scannerState == .ready {
                            QRScanner(onCode: model.pair, onError: { model.refreshScanner(scannerFailed: true) })
                                .frame(maxWidth:.infinity,maxHeight:.infinity)
                        } else {
                            VStack(spacing:12) {
                                switch model.scannerState {
                                case .awaitingPermission:
                                    ProgressView("Waiting for camera access…")
                                case .denied:
                                    Text("Camera access is off").font(.headline)
                                    Text("Turn on Camera in Trackypady’s settings to scan the QR code on your Mac.")
                                    Button("Open Settings", action: openCameraSettings)
                                        .buttonStyle(.borderedProminent)
                                case .restricted:
                                    Text("Camera access is restricted").font(.headline)
                                    Text("Check Screen Time restrictions or ask your device administrator to allow Camera.")
                                case .unavailable:
                                    Text("Scanner unavailable").font(.headline)
                                    Text("Open the iPhone Camera app, scan the QR code on your Mac, then tap the link.")
                                case .ready: EmptyView()
                                }
                            }.font(.callout).multilineTextAlignment(.center).padding(24)
                                .frame(maxWidth:.infinity,maxHeight:.infinity)
                        }
                    }
                        .navigationTitle("Scan Bridge QR").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Cancel") { model.scanning=false } } }
                }
            }
            .onAppear { UIApplication.shared.isIdleTimerDisabled = phase == .active }
            .onChange(of:phase) { value in
                UIApplication.shared.isIdleTimerDisabled = value == .active
                if value == .background { model.suspend() }
                if value == .active { activate() }
            }
        }
    }

    private var phoneFooter: some View {
        VStack(spacing: 6) {
            Button("Try gesture demo") { practicing = true }
                .buttonStyle(OnboardingButtonStyle(filled: false, ink: skin.ink, paper: skin.background))
            Text("Mac bridge not required.")
                .font(.caption)
                .foregroundStyle(skin.ink.opacity(0.74))
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
    }

    private var infoMenu: some View {
        Menu {
            Button("Help") { presentedInfo = .help }
            Button("Privacy") { presentedInfo = .privacy }
            Button("Version") { presentedInfo = .version }
        } label: {
            Image(systemName: "info.circle")
                .font(.title3)
                .foregroundStyle(skin.ink.opacity(0.35))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Help, privacy and version")
    }

    private static let privacyURL = URL(string: "https://deepinteractionlab.github.io/trackypady/privacy/")!
    private static let supportURL = URL(string: "https://deepinteractionlab.github.io/trackypady/support/")!

    private func openCameraSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        // Changing camera access in Settings can cause iOS to relaunch the app.
        resumeScannerAfterSettings = true
        UIApplication.shared.open(url) { opened in
            if !opened { resumeScannerAfterSettings = false }
        }
    }

    private func activate() {
        if resumeScannerAfterSettings {
            resumeScannerAfterSettings = false
            model.scan()
        } else {
            model.refreshScanner()
        }
        model.start()
    }

    private func openPairingLink(_ url: URL) {
        guard (try? TouchPairing.parseQR(url.absoluteString)) != nil else {
            invalidPairingLink = true
            return
        }
        practicing = false
        resumeScannerAfterSettings = false
        model.pair(url.absoluteString)
    }
}

private struct OnboardingButtonStyle: ButtonStyle {
    let filled: Bool
    let ink: Color
    let paper: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .foregroundStyle(filled ? paper : ink)
            .background(Capsule().fill(filled ? ink : .clear))
            .overlay { Capsule().strokeBorder(ink.opacity(filled ? 0 : 0.4)) }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String)->Void
    let onError: () -> Void
    func makeUIViewController(context: Context) -> QRScannerController {
        QRScannerController(onCode:onCode,onError:onError)
    }
    func updateUIViewController(_ controller: QRScannerController,context: Context) {}
    static func dismantleUIViewController(_ controller: QRScannerController,coordinator: ()) {
        controller.scanner.stopScanning()
    }
}

@MainActor
private final class QRScannerController: UIViewController, DataScannerViewControllerDelegate {
    let scanner=DataScannerViewController(recognizedDataTypes:[.barcode(symbologies:[.qr])],
        qualityLevel:.balanced,recognizesMultipleItems:false,isHighFrameRateTrackingEnabled:false,
        isPinchToZoomEnabled:true,isGuidanceEnabled:true,isHighlightingEnabled:true)
    private let onCode: (String)->Void
    private let onError: () -> Void
    init(onCode: @escaping (String)->Void,onError: @escaping () -> Void) {
        self.onCode=onCode; self.onError=onError
        super.init(nibName:nil,bundle:nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        scanner.delegate=self
        addChild(scanner); view.addSubview(scanner.view); scanner.didMove(toParent:self)
        scanner.view.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([
            scanner.view.leadingAnchor.constraint(equalTo:view.leadingAnchor),
            scanner.view.trailingAnchor.constraint(equalTo:view.trailingAnchor),
            scanner.view.topAnchor.constraint(equalTo:view.topAnchor),
            scanner.view.bottomAnchor.constraint(equalTo:view.bottomAnchor)])
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        do { try scanner.startScanning() }
        catch { onError() }
    }
    override func viewWillDisappear(_ animated: Bool) {
        scanner.stopScanning(); super.viewWillDisappear(animated)
    }
    func dataScanner(_ dataScanner: DataScannerViewController,didAdd addedItems: [RecognizedItem],allItems: [RecognizedItem]) {
        for item in addedItems {
            guard case .barcode(let barcode)=item,let text=barcode.payloadStringValue else { continue }
            // Keep scanning unrelated codes; never open URLs from camera input.
            guard (try? TouchPairing.parseQR(text)) != nil else { continue }
            scanner.stopScanning(); onCode(text); return
        }
    }
    func dataScanner(_ dataScanner: DataScannerViewController,becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
        onError()
    }
}

private enum PhoneInfoSheet: String, Identifiable {
    case help, privacy, version
    var id: Self { self }
}

// Native in-app browser preserves standard loading, links and Done controls
// while using the same modal sheet presentation as Version.
private struct PhoneInfoBrowser: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
