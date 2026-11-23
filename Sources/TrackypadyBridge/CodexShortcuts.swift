// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import AppKit
import TouchCore

enum BridgeShortcut: String, CaseIterable, Identifiable {
    var id: Self { self }
    case dictate = "globalDictationHold", steer = "composer.steer", queue = "composer.queue"
    var title: String {
        switch self { case .dictate: "Dictate"; case .steer: "Steer"; case .queue: "Queue" }
    }
}

struct ShortcutChord: Equatable {
    struct Modifier: Equatable {
        let code: CGKeyCode
        let flag: CGEventFlags
    }
    let modifiers: [Modifier]
    let key: String?

    init?(_ text: String) {
        let parts = text.lowercased().components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        var modifiers: [Modifier] = []
        var key: String?
        for part in parts {
            let modifier: Modifier
            switch part {
            case "ctrl", "control", "leftcontrol", "leftctrl": modifier = Modifier(code: 59, flag: .maskControl)
            case "rightcontrol", "rightctrl": modifier = Modifier(code: 62, flag: .maskControl)
            case "alt", "option", "leftalt", "leftoption": modifier = Modifier(code: 58, flag: .maskAlternate)
            case "rightalt", "rightoption": modifier = Modifier(code: 61, flag: .maskAlternate)
            case "shift", "leftshift": modifier = Modifier(code: 56, flag: .maskShift)
            case "rightshift": modifier = Modifier(code: 60, flag: .maskShift)
            case "cmd", "command", "meta", "super", "cmdorctrl", "commandorcontrol", "leftcommand", "leftmeta": modifier = Modifier(code: 55, flag: .maskCommand)
            case "rightcommand", "rightmeta": modifier = Modifier(code: 54, flag: .maskCommand)
            case "fn", "globe": modifier = Modifier(code: 63, flag: .maskSecondaryFn)
            default:
                guard key == nil else { return nil }
                let normalized = Self.aliases[part] ?? part
                guard Self.keyCodes[normalized] != nil || (normalized.count == 1 && normalized.first?.isWhitespace == false) else { return nil }
                key = normalized
                continue
            }
            guard !modifiers.contains(where: { $0.flag == modifier.flag }) else { return nil }
            modifiers.append(modifier)
        }
        self.modifiers = modifiers.sorted { $0.code > $1.code }
        self.key = key
    }

    private static let aliases = ["return":"enter", "esc":"escape", "arrowleft":"left", "arrowright":"right",
                                  "arrowup":"up", "arrowdown":"down", "spacebar":"space", "minus":"-", "comma":",", "period":"."]
    private static let keyCodes: [String: CGKeyCode] = [
        "enter":36, "tab":48, "space":49, "backspace":51, "escape":53, "delete":117,
        "left":123, "right":124, "down":125, "up":126, "home":115, "end":119, "pageup":116, "pagedown":121,
        "f1":122, "f2":120, "f3":99, "f4":118, "f5":96, "f6":97, "f7":98, "f8":100, "f9":101,
        "f10":109, "f11":103, "f12":111, "f13":105, "f14":107, "f15":113, "f16":106,
        "f17":64, "f18":79, "f19":80, "f20":90
    ]
    static func namedKey(for code: CGKeyCode) -> String? {
        keyCodes.first { $0.value == code }?.key.capitalized
    }
    var flags: CGEventFlags { modifiers.reduce(CGEventFlags()) { $0.union($1.flag) } }
    @MainActor func keyCode() throws -> CGKeyCode? {
        guard let key else { return nil }
        if let code = Self.keyCodes[key] { return code }
        return try MacKeyboardLayout.keyCode(for: key)
    }
    @MainActor func holdEvents() throws -> [(down: CGEvent, up: CGEvent)] {
        var flags = CGEventFlags()
        var events: [(down: CGEvent, up: CGEvent)] = []
        func appendKey(_ code: CGKeyCode, adding modifier: CGEventFlags? = nil) throws {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
                throw CocoaError(.coderInvalidValue)
            }
            up.flags = flags
            if let modifier {
                flags.insert(modifier)
                down.type = .flagsChanged
                up.type = .flagsChanged
            }
            down.flags = flags
            events.append((down, up))
        }
        for modifier in modifiers { try appendKey(modifier.code, adding: modifier.flag) }
        if let code = try keyCode() { try appendKey(code) }
        return events
    }
    @MainActor func tapEvents() throws -> [CGEvent] {
        let events = try holdEvents()
        // Release the letter first, then each modifier in reverse order. A
        // flag-bearing letter key-up alone can leave synthetic modifiers down.
        return events.map(\.down) + events.reversed().map(\.up)
    }
}

struct CodexShortcuts: Equatable {
    struct Binding: Equatable {
        let display: String
        let chord: ShortcutChord?
        var usesToggleDictation = false
        var usesComposerControls = false
        var alternateSubmitChord: ShortcutChord? = nil
        var alternateUnavailableReason: String? = nil
        var requiresRestart = false
    }

    private var values: [BridgeShortcut: Binding] = [:]
    subscript(command: BridgeShortcut) -> Binding {
        values[command] ?? Binding(display: "No saved shortcut", chord: nil)
    }

    static var home: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static func load() -> Self {
        load(from: home)
    }

    private struct ComposerPreferences {
        var enterBehavior = "enter"
        var migratedFollowUp = false
        var explicitFollowUp = false
        var queueNeedsPreference: Bool { migratedFollowUp && !explicitFollowUp }
    }
    private static func composerPreferences(in home: URL) throws -> ComposerPreferences {
        let path = home.appendingPathComponent("config.toml")
        let text: String
        do { text = try String(contentsOf: path, encoding: .utf8) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return ComposerPreferences() }
        var result = ComposerPreferences()
        var inDesktop = false
        for raw in text.components(separatedBy: .newlines) {
            // These preferences are simple scalars; ignore unrelated configuration.
            let line = raw.split(separator: "#", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
            if line.hasPrefix("[") { inDesktop = line == "[desktop]"; continue }
            guard inDesktop, let equal = line.firstIndex(of: "=") else { continue }
            let key = line[..<equal].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch key {
            case "composerEnterBehavior":
                guard ["enter", "cmdIfMultiline", "cmdAlways"].contains(value) else { throw CocoaError(.fileReadCorruptFile) }
                result.enterBehavior = value
            case "migratedFollowUpQueueToSteer": result.migratedFollowUp = value == "true"
            case "followUpQueueMode":
                guard ["steer", "queue", "interrupt"].contains(value) else { throw CocoaError(.fileReadCorruptFile) }
                result.explicitFollowUp = true
            default: break
            }
        }
        return result
    }

    static func load(from home: URL, keybindingsData: Data? = nil) -> Self {
        struct Entry: Decodable { let command: String; let key: String? }
        struct LegacyVoice: Decodable { let globalDictationHotkey: String?; let globalDictationToggleHotkey: String? }
        let file = home.appendingPathComponent("keybindings.json")
        var result = Self()
        do {
            let data: Data
            do { data = try keybindingsData ?? Data(contentsOf: file) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { data = Data() }
            var entries = data.allSatisfy { [9, 10, 13, 32].contains($0) } ? [] : try JSONDecoder().decode([Entry].self, from: data)
            if !entries.contains(where: { $0.command == BridgeShortcut.dictate.rawValue }) {
                let oldToggle = entries.first { $0.command == "globalDictationToggle" }
                var saved = oldToggle?.key
                if saved == nil, let data = try? Data(contentsOf: home.appendingPathComponent(".codex-global-state.json")),
                   let voice = try? JSONDecoder().decode(LegacyVoice.self, from: data) {
                    saved = voice.globalDictationHotkey == nil ? voice.globalDictationToggleHotkey : voice.globalDictationHotkey
                    if voice.globalDictationHotkey == "Fn" { saved = nil }
                }
                if let saved {
                    entries.removeAll { $0.command == "globalDictationToggle" }
                    entries.append(Entry(command: BridgeShortcut.dictate.rawValue, key: saved))
                }
            }
            // These commands have no global/default binding in Codex 26.1111.
            // Use its normal composer controls when the user has not overridden them.
            let preferences = try composerPreferences(in: home)
            for command in BridgeShortcut.allCases {
                let bindings = entries.filter { $0.command == command.rawValue }
                if bindings.isEmpty {
                    if command == .dictate {
                        let toggle = entries.filter { $0.command == "composer.toggleDictation" }
                        if toggle.contains(where: { $0.key == nil }) {
                            result.values[command] = Binding(display: "Disabled in Codex", chord: nil)
                        } else {
                            let keys = toggle.isEmpty ? ["Cmd+Shift+D"] : toggle.compactMap(\.key)
                            let key = keys.first { text in
                                guard let chord = ShortcutChord(text), chord.key != nil else { return false }
                                return !entries.contains { $0.command != "composer.toggleDictation" && $0.key.flatMap(ShortcutChord.init) == chord }
                            }
                            result.values[command] = Binding(display: key.map { "\($0) · Codex composer" } ?? "Dictation shortcut unavailable",
                                chord: key.flatMap(ShortcutChord.init), usesToggleDictation: true)
                        }
                    } else {
                        let alternate = ShortcutChord(preferences.enterBehavior == "enter" ? "Cmd+Enter" : "Cmd+Shift+Enter")!
                        let conflict = entries.contains { $0.command == "composer.submit" || $0.key.flatMap(ShortcutChord.init) == alternate }
                        let migration = command == .queue && preferences.queueNeedsPreference
                        result.values[command] = Binding(display: "Codex default controls", chord: nil,
                            usesComposerControls: true, alternateSubmitChord: conflict || migration ? nil : alternate,
                            alternateUnavailableReason: migration
                                ? "Select Steer or Queue explicitly in Codex Settings, then refresh bridge shortcuts · Codex’s migration can otherwise turn Queue into Steer"
                                : "Codex’s alternate send shortcut is overridden · check shortcuts before sending")
                    }
                    continue
                }
                if bindings.contains(where: { $0.key == nil }) {
                    result.values[command] = Binding(display: "Disabled in Codex", chord: nil)
                    continue
                }
                let shortcuts = bindings.compactMap(\.key)
                for text in shortcuts {
                    guard let chord = ShortcutChord(text), command == .dictate || chord.key != nil else { continue }
                    guard !entries.contains(where: { $0.command != command.rawValue && $0.key.flatMap(ShortcutChord.init) == chord }) else { continue }
                    result.values[command] = Binding(display: text, chord: chord)
                    break
                }
                if result.values[command] == nil {
                    result.values[command] = Binding(display: "\(shortcuts.joined(separator: ", ")) (unavailable)", chord: nil)
                }
            }
        } catch {
            for command in BridgeShortcut.allCases { result.values[command] = Binding(display: "Couldn’t read Codex shortcuts", chord: nil) }
        }
        return result
    }
}

/// The visible composer button determines the primary action. The alternate
/// Enter gesture flips Steer/Queue only while a response is active.
enum CodexDefaultSubmission {
    enum Plan: Equatable { case pressButton, alternateShortcut, unavailable }
    static func plan(button: String, queue: Bool, alternateAvailable: Bool) -> Plan {
        if button == "Send" || button == (queue ? "Queue" : "Steer") { return .pressButton }
        if button == (queue ? "Steer" : "Queue"), alternateAvailable { return .alternateShortcut }
        return .unavailable
    }
}
