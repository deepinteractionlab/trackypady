// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation
@preconcurrency import Network
import TouchCore

// The first three frames elect a route before either peer can send gestures.
enum LocalFrame: Codable, Sendable {
    case available, claim(PhoneConnectionAttempt), accepted(BridgeStatus)
    case request(WakeRequest), receipt(WakeReceipt)
    case preview(HapticPreviewCommand), discard(DiscardInputAcknowledgement)
    case pairingRevoked
}

@MainActor
final class LocalChannel {
    let id = UUID()
    private let connection: NWConnection
    private(set) var localNetworkDenied = false
    private var closed = false
    private var timer: Task<Void, Never>?
    var onReady: () -> Void = {}
    var onFrame: (LocalFrame) -> Void = { _ in }
    var onClose: () -> Void = {}

    init(_ connection: NWConnection) { self.connection = connection }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            // All Network.framework callbacks for this connection use the main queue.
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                self.localNetworkDenied = self.connection.currentPath?.unsatisfiedReason == .localNetworkDenied
                switch state {
                case .ready: self.onReady(); self.read()
                case .failed, .cancelled: self.close()
                default: break
                }
            }
        }
        armTimeout(seconds: 10)
        connection.start(queue: .main)
    }

    func armTimeout(seconds: Int) {
        timer?.cancel()
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.close()
        }
    }

    private func read() {
        guard !closed else { return }
        TouchWire.receive(LocalFrame.self, from: connection) { [weak self] frame in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                guard let frame else { self.close(); return }
                self.onFrame(frame)
                self.read()
            }
        }
    }

    @discardableResult func send(_ frame: LocalFrame) -> Bool {
        guard !closed, let packet = try? TouchWire.packet(frame) else { close(); return false }
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if error != nil { MainActor.assumeIsolated { self?.close() } }
        })
        return true
    }

    func close() {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose()
    }
}

enum TouchRoute: Equatable {
    case local(UUID), bluetooth(UUID)
    var id: UUID {
        switch self { case .local(let id), .bluetooth(let id): return id }
    }
    var label: String {
        switch self { case .local: return "Wi-Fi"; case .bluetooth: return "Bluetooth" }
    }
}
