// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation

/// This Codex build reports global hold-to-dictate in its main-process log.
/// Observe only new lifecycle events for the foreground process and one attempt.
final class GlobalDictationObservation {
    enum Phase { case waiting, recording, stopping, completed, cancelled, failed }
    private(set) var phase = Phase.waiting
    private var attempt: Substring?
    private let path: URL
    private var recoveryIsCurrent = true
    private(set) var hasLoggedFailure = false
    private var failedInOverlay = false
    private var caughtUp = true
    private let file: FileHandle
    private var partial = Data()

    static func currentLog(pid: pid_t) -> URL? {
        let calendar = Calendar(identifier: .gregorian)
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/com.openai.codex")
        let now = Date()
        // The desktop logger uses UTC date directories.
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = utc.dateComponents([.year, .month, .day], from: now)
        let folder = logs.appendingPathComponent(String(format: "%04d/%02d/%02d", day.year!, day.month!, day.day!))
        guard let paths = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let files = paths.filter { $0.lastPathComponent.contains("-\(pid)-t0-") && $0.pathExtension == "log" }
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return files.max(by: { modified($0) < modified($1) })
    }

    convenience init?(pid: pid_t) {
        guard let path = Self.currentLog(pid: pid) else { return nil }
        self.init(path: path)
    }

    init?(path: URL) {
        guard let handle = try? FileHandle(forReadingFrom: path), (try? handle.seekToEnd()) != nil else { return nil }
        self.path = path
        file = handle
    }

    var hasObservedAttempt: Bool { attempt != nil }

    func confirmsFinishedAttempt(currentLog: URL?) -> Bool {
        guard isLatestAttempt(currentLog: currentLog) else { return false }
        return phase == .completed || phase == .cancelled || (phase == .failed && hasLoggedFailure)
    }

    func ownsFailedOverlay(currentLog: URL?) -> Bool {
        isLatestAttempt(currentLog: currentLog) && phase == .failed && failedInOverlay
    }

    func isLatestAttempt(currentLog: URL?) -> Bool {
        guard currentLog == path else { return false }
        _ = poll()
        return attempt != nil && recoveryIsCurrent && caughtUp && partial.isEmpty
    }

    func poll() -> Phase {
        do {
            let bytes = try file.read(upToCount: 131072) ?? Data()
            caughtUp = bytes.count < 131072
            partial.append(bytes)
            while let newline = partial.firstIndex(of: 10) {
                let line = String(decoding: partial[..<newline], as: UTF8.self)
                partial.removeSubrange(...newline)
                guard line.contains(" dictation.startup "), line.contains(" surface=global ") else { continue }
                let fields = line.split(separator: " ")
                guard let id = fields.first(where: { $0.hasPrefix("attemptId=") }),
                      let stage = fields.first(where: { $0.hasPrefix("stage=") }) else { continue }
                if stage == "stage=renderer_start" {
                    if let attempt, attempt != id { recoveryIsCurrent = false }
                    if attempt == nil, line.contains(" startGesture=press-and-hold ") { attempt = Substring(String(id)) }
                }
                guard attempt == id else { continue }
                switch stage {
                case "stage=recording_started", "stage=first_audio": phase = .recording
                case "stage=stop_requested": phase = .stopping
                case "stage=cancelled": phase = .cancelled
                case "stage=completed": phase = .completed
                case "stage=failed", "stage=error":
                    phase = .failed
                    hasLoggedFailure = true
                    failedInOverlay = fields.contains("rendererWindowAppearance=globalDictation")
                default: break
                }
            }
            if partial.count > 131072 { partial.removeAll(); recoveryIsCurrent = false }
        } catch { phase = .failed; recoveryIsCurrent = false }
        return phase
    }
}
