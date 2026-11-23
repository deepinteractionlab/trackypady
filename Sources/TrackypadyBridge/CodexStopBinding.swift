// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit

/// Read-only compatibility adapter, not a general JavaScript parser or a public Codex API.
/// Full recognizes reviewed internals; Limited uses the standard double-Escape shortcut.
enum CodexStopBinding {
    enum Failure: LocalizedError {
        case unavailable, unsupported, changed
        var errorDescription: String? {
            switch self {
            case .unavailable: "Cannot read Codex Stop shortcut · reopen Setup to check again"
            case .unsupported: "Codex Stop shortcut is not recognized · update Trackypady before using Stop"
            case .changed: "Codex changed · restart Codex to recheck Stop"
            }
        }
    }

    struct Installation: Equatable, Sendable {
        let bundleURL: URL
        let build: String
        let archiveSize: UInt64
        let archiveModified: Date
        let archiveFileID: UInt64
        var archiveURL: URL { bundleURL.appendingPathComponent("Contents/Resources/app.asar") }

        static func read(_ url: URL) throws -> Self {
            let url = url.resolvingSymlinksInPath().standardizedFileURL
            let plist = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            guard let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == "com.openai.codex",
                  let build = info["CFBundleVersion"] as? String else { throw Failure.unavailable }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent("Contents/Resources/app.asar").path)
            guard let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date,
                  let fileID = attributes[.systemFileNumber] as? NSNumber else { throw Failure.unavailable }
            return Self(bundleURL: url, build: build, archiveSize: size.uint64Value,
                        archiveModified: modified, archiveFileID: fileID.uint64Value)
        }
    }

    struct Verification: Equatable, Sendable {
        let installation: Installation
        var display: String { "Matches system binding" }
        func isCurrent(bundleURL: URL?, launchedAt: Date?) -> Bool {
            guard let bundleURL, let launchedAt,
                  // An updater can replace the files while the old process still runs.
                  installation.archiveModified <= launchedAt else { return false }
            return (try? Installation.read(bundleURL)) == installation
        }
    }

    enum Path: String, Sendable {
        case full = "Full", limited = "Limited"
        var detail: String { "Path: " + rawValue }
    }

    /// Captured before preparation/dispatch. Both paths retain installation freshness checks.
    struct Selection: Equatable, Sendable {
        let path: Path
        let installation: Installation
        func isCurrent(bundleURL: URL?, launchedAt: Date?) -> Bool {
            Verification(installation: installation).isCurrent(bundleURL: bundleURL, launchedAt: launchedAt)
        }
    }

    static func select(bundleURL: URL,
                       inspect: (URL) throws -> Verification = { try Self.inspect(bundleURL: $0) }) throws -> Selection {
        let before = try Installation.read(bundleURL)
        let path: Path
        do {
            let verified = try inspect(bundleURL)
            guard verified.installation == before else { throw Failure.changed }
            path = .full
        } catch Failure.unsupported {
            path = .limited
        }
        // An update during either inspection must never become a fallback dispatch.
        guard try Installation.read(bundleURL) == before else { throw Failure.changed }
        return Selection(path: path, installation: before)
    }

    struct Signature: Sendable {
        let assetStem: String
        let start: String
        let end: String
        let sha256: String
    }

    // Reviewed against Codex build 27194, then physically confirmed by Sandra.
    // Hash only the relevant functions: unrelated edits in the asset need not disable Stop.
    static let signatures = [
        Signature(assetStem: "486887.", start: "if(\"Escape\"!==e.key||!document.hasFocus())return;",
                  end: "case null:return}}", sha256: "1f065401fa6c686770ddc474bf391e9be410cadd74713e9518025cdb10dc9614"),
        Signature(assetStem: "907538.", start: "function({isComposing:e,isDictating:t,realtimeSessionPhase:n,followUpType:r,isResponseInProgress:i,canStopFromEscape:",
                  end: "?\"stop-turn\":\"confirm-stop-turn\"}", sha256: "52658f7e4c65c6f0f14927ef259590778f17ab2bf26752c740ab62d62257f829")
    ]

    static func inspect(bundleURL: URL) throws -> Verification {
        do {
            let before = try Installation.read(bundleURL)
            try inspectArchive(before.archiveURL)
            guard try Installation.read(bundleURL) == before else { throw Failure.changed }
            return Verification(installation: before)
        } catch let failure as Failure { throw failure }
        catch { throw Failure.unavailable }
    }

    /// Bounded ASAR reads: the header and two candidate assets, never the whole app archive.
    /// Entry paths are not followed or executed; unpacked and linked entries are rejected.
    static func inspectArchive(_ url: URL, signatures: [Signature] = signatures) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard count >= 0, offset <= length, UInt64(count) <= length - offset else { throw Failure.unavailable }
            try file.seek(toOffset: offset)
            guard let bytes = try file.read(upToCount: count), bytes.count == count else { throw Failure.unavailable }
            return bytes
        }
        let prefix = try read(0, 16)
        func word(_ offset: Int) -> UInt64 {
            (0..<4).reduce(0) { $0 | UInt64(prefix[offset + $1]) << (8 * $1) }
        }
        let headerSize = word(4), jsonSize = word(12), contentOffset = 8 + headerSize
        guard word(0) == 4, headerSize >= 8, jsonSize <= 8 * 1024 * 1024,
              jsonSize <= headerSize - 8, contentOffset <= length else { throw Failure.unavailable }
        let data = try read(16, Int(jsonSize))
        guard var directory = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unavailable }
        for component in ["webview", "assets", "async"] {
            guard let files = directory["files"] as? [String: Any],
                  let next = files[component] as? [String: Any], next["link"] == nil else { throw Failure.unsupported }
            directory = next
        }
        guard let files = directory["files"] as? [String: [String: Any]] else { throw Failure.unsupported }
        for signature in signatures {
            let candidates = files.filter { $0.key.hasPrefix(signature.assetStem) && $0.key.hasSuffix(".js") }
            guard candidates.count == 1, let entry = candidates.first?.value,
                  entry["unpacked"] as? Bool != true, entry["link"] == nil,
                  let offsetText = entry["offset"] as? String, let offset = UInt64(offsetText),
                  let size = entry["size"] as? Int, size > 0, size <= 16 * 1024 * 1024,
                  offset <= length - contentOffset else { throw Failure.unsupported }
            let bytes = try read(contentOffset + offset, size)
            guard let source = String(data: bytes, encoding: .utf8),
                  let start = source.range(of: signature.start),
                  source.range(of: signature.start, range: start.upperBound..<source.endIndex) == nil else { throw Failure.unsupported }
            let limit = source.index(start.lowerBound, offsetBy: 8192, limitedBy: source.endIndex) ?? source.endIndex
            guard let end = source.range(of: signature.end, range: start.upperBound..<limit) else { throw Failure.unsupported }
            let body = Data(source[start.lowerBound..<end.upperBound].utf8)
            let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            guard digest == signature.sha256 else { throw Failure.unsupported }
        }
    }
}
