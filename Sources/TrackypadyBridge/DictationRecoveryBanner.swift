// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation

@MainActor
enum DictationRecoveryBanner {
    struct Failure: LocalizedError {
        var errorDescription: String? { "Dismiss the Dictation stopped banner in Codex, then hold again" }
    }

    static func isRecorderWindow(title: String?, document: String?) -> Bool {
        if let document, let url = URL(string: document) {
            if url.path == "/global-dictation" || url.fragment == "/global-dictation" { return true }
        }
        return title == "Dictation"
    }

    /// A fresh hold can press Dismiss once. Confirm the banner disappeared before sending any keys.
    static func dismissIfPresent<Button>(timeout: Duration = .seconds(1),
                                        isCurrent: () -> Bool,
                                        locate: () throws -> Button?,
                                        press: (Button) throws -> Void) async throws {
        guard isCurrent() else { throw CancellationError() }
        guard let button = try locate() else { return }
        guard isCurrent() else { throw CancellationError() }
        try press(button)
        let deadline = ContinuousClock.now + timeout
        repeat {
            guard isCurrent() else { throw CancellationError() }
            if try locate() == nil { return }
            guard ContinuousClock.now < deadline else { throw Failure() }
            try await Task.sleep(for: .milliseconds(50))
        } while true
    }
}
