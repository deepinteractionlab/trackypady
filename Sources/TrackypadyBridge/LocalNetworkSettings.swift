// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import AppKit
import ApplicationServices

@available(macOS 15, *)
enum LocalNetworkSettings {
    static let manualPath = "In System Settings, choose Privacy & Security → Local Network."

    @MainActor
    static func open() async -> String? {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork"),
              NSWorkspace.shared.open(url) else { return manualPath }

        // Some versions of Settings accept the link but open only the parent pane.
        guard AXIsProcessTrusted() else { return manualPath }
        let names = localizedPageNames()
        let deadline = ContinuousClock.now + .seconds(5)
        var sawSettings = false
        var pressed = false
        while !Task.isCancelled && ContinuousClock.now < deadline {
            if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.apple.systempreferences" {
                sawSettings = true
                let settings = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(settings, 0.25)
                if let window = (read(settings, kAXWindowsAttribute) as? [AXUIElement])?.first {
                    if let title = read(window, kAXTitleAttribute) as? String, names.contains(title) { return nil }
                    if !pressed, let row = navigationButton(in: window, names: names) {
                        pressed = AXUIElementPerformAction(row, kAXPressAction as CFString) == .success
                    }
                }
            } else if sawSettings { break }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return nil }
        }
        return manualPath
    }

    private static func localizedPageNames() -> Set<String> {
        // The navigator identifier can include the translated row label. Use the
        // installed Settings translations, including per-app language overrides.
        var names: Set<String> = ["Local Network"]
        if let library = FileManager.default.urls(for: .libraryDirectory, in: .systemDomainMask).first {
            let table = library.appendingPathComponent("ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents/Resources/Localizable.loctable")
            if let data = try? Data(contentsOf: table),
               let translations = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
                for case let strings as [String: Any] in translations.values {
                    if let name = strings["LOCAL_NETWORK"] as? String { names.insert(name) }
                }
            }
        }
        return names
    }

    private static func navigationButton(in window: AXUIElement, names: Set<String>) -> AXUIElement? {
        let identifiers = Set(names.map { $0 + "_Navigator" })
        var stack = [window]
        for _ in 0..<300 {
            guard let element = stack.popLast() else { break }
            if read(element, kAXRoleAttribute) as? String == kAXButtonRole,
               let id = read(element, kAXIdentifierAttribute) as? String, identifiers.contains(id) { return element }
            if let children = read(element, kAXChildrenAttribute) as? [AXUIElement] { stack.append(contentsOf: children) }
        }
        return nil
    }

    private static func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
