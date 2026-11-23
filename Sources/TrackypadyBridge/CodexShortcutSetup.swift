// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation

/// File-based setup for the installed Codex keymap. Does not activate shortcuts or restart Codex.
public enum CodexShortcutSetup {
    public static let bindings = [
        (command: "globalDictationHold", key: "Ctrl+Alt+Shift+D"),
        (command: "composer.steer", key: "Ctrl+Alt+Shift+S"),
        (command: "composer.queue", key: "Ctrl+Alt+Shift+Q")
    ]
    public enum SetupError: LocalizedError {
        case invalidFile, conflict(String), changed, symbolicLink, verification
        public var errorDescription: String? {
            switch self {
            case .invalidFile: "Codex shortcuts file is invalid. Nothing was changed."
            case .conflict(let command): "Shortcut conflict for \(command). Review Codex Keyboard shortcuts; nothing was changed."
            case .changed: "Codex shortcuts changed. Review your edits before pushing again."
            case .symbolicLink: "Codex shortcuts file is a symbolic link. Configure its shortcuts in Codex Settings."
            case .verification: "Could not verify Codex shortcuts after writing. The original backup is available beside keybindings.json."
            }
        }
    }
    struct Snapshot {
        let data: Data?
        var entries: [[String: Any]]

        func rows(_ command: BridgeShortcut) -> [[String: Any]] {
            entries.filter { $0["command"] as? String == command.rawValue }
        }

        func conflict(_ chord: ShortcutChord, for command: String) -> String? {
            entries.first { row in
                row["command"] as? String != command && (row["key"] as? String).flatMap(ShortcutChord.init) == chord
            }?["command"] as? String
        }
    }

    static func read(_ url: URL) throws -> Snapshot {
        let fm = FileManager.default
        do {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw SetupError.symbolicLink }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Snapshot(data: nil, entries: [])
        }
        let data = try Data(contentsOf: url)
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              entries.allSatisfy({ ($0["command"] as? String)?.isEmpty == false &&
                  ($0["key"] is String || $0["key"] is NSNull) }) else { throw SetupError.invalidFile }
        return Snapshot(data: data, entries: entries)
    }

    static func configure(at url: URL, snapshot: Snapshot, edits: [BridgeShortcut: String],
                          fillingMissing: Bool = false) throws -> [String] {
        let original = snapshot.data
        guard try read(url).data == original else { throw SetupError.changed }
        var next = snapshot
        var issues: [String] = []
        for (command, key) in edits {
            guard let chord = ShortcutChord(key), command == .dictate || chord.key != nil else {
                throw SetupError.conflict(command.title + " (invalid shortcut)")
            }
            let indices = next.entries.indices.filter { next.entries[$0]["command"] as? String == command.rawValue }
            if fillingMissing {
                guard indices.isEmpty else { continue }
                if let owner = next.conflict(chord, for: command.rawValue) {
                    issues.append("\(command.title): \(key) is assigned to \(owner).")
                    continue
                }
            }
            if let index = indices.first {
                guard indices.count == 1 else { throw SetupError.conflict(command.title + " has multiple bindings; edit it in Codex") }
                next.entries[index]["key"] = key
            } else {
                next.entries.append(["command": command.rawValue, "key": key])
            }
        }
        if !fillingMissing {
            for (command, key) in edits {
                if let chord = ShortcutChord(key), let owner = next.conflict(chord, for: command.rawValue) {
                    throw SetupError.conflict(command.title + " (" + key + " is assigned to " + owner + ")")
                }
            }
        }
        guard !(next.entries as NSArray).isEqual(to: snapshot.entries) else { return issues }
        let updated = try JSONSerialization.data(withJSONObject: next.entries, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let original {
            let stamp = Int(Date().timeIntervalSince1970)
            let path = url.appendingPathExtension("backup-\(stamp)-\(UUID().uuidString)")
            try original.write(to: path, options: .withoutOverwriting)
        }
        // Best-effort concurrent-change check; external writers do not share a lock with us.
        let current = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard current == original else { throw SetupError.changed }
        try updated.write(to: url, options: .atomic)
        let written = try Data(contentsOf: url)
        guard written == updated else { throw SetupError.verification }
        return issues
    }
}
