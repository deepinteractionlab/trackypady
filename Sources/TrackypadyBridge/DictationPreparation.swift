// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Reserves the native start while asynchronous focus discovery is in progress.
@MainActor
final class DictationPreparation {
    private var pending: UUID?

    func begin() -> UUID? {
        guard pending == nil else { return nil }
        let token = UUID()
        pending = token
        return token
    }

    func resolve<T>(_ token: UUID, connectionIsCurrent: () -> Bool,
                    discover: @MainActor () async throws -> T) async throws -> T {
        let target = try await discover()
        guard isCurrent(token), connectionIsCurrent() else { throw CancellationError() }
        return target
    }

    func isCurrent(_ token: UUID) -> Bool { pending == token }
    func finish(_ token: UUID) { if isCurrent(token) { pending = nil } }
    func cancel() { pending = nil }
}
