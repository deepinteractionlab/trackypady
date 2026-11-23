// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation
import TouchCore

/// The activity history stores labels derived from protocol state, never payload text.
struct BridgeEvent: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let title: String
    let result: String
    var requestID: UUID?
    var failed = false
    let stopPath: CodexStopBinding.Path?

    init(_ title: String, _ result: String, requestID: UUID? = nil, failed: Bool = false, stopPath: CodexStopBinding.Path? = nil) {
        self.stopPath = stopPath
        self.title = title
        self.result = result
        self.requestID = requestID
        self.failed = failed
    }

    init(request: WakeRequest, receipt: WakeReceipt, stopPath: CodexStopBinding.Path? = nil) {
        let action: String = switch request.action {
        case .wakeCodex: "Wake"
        case .startDictation: "Start dictation"
        case .stopDictation: "End dictation"
        case .dictationHeartbeat: "Recording check"
        case .getStatus: "Status"
        case .sendSteering: "Steer"
        case .sendQueue: "Queue"
        case .discardDraft: "Discard"
        case .prepareResponseStop: "Prepare Stop"
        case .stopResponse: "Stop"
        }
        let summary: String = switch receipt.outcome {
        case .foreground: "Codex in foreground"
        case .dictationRecording: "Recording acknowledged"
        case .dictationStopped: "Recording ended"
        case .status: "Status received"
        case .queueSent, .steeringSent: "Shortcut sent"
        case .draftSelected: "Draft selected"
        case .draftDiscarded: "Selected text deleted"
        case .draftEditRequested: "Edit requested · confirmation unavailable"
        case .stopPrepared: "Stop target ready"
        case .noActiveResponse: "No matching active response"
        case .stopPressed: "Stop shortcut sent"
        case .failed:
            receipt.isComposerFocusFailure ? "Main chat input needs focus" :
                Self.failureSummary(action: request.action, message: receipt.message)
        }
        self.init(action, summary, requestID: request.id, failed: receipt.outcome == .failed,
                  stopPath: request.action == .stopResponse && receipt.outcome == .stopPressed ? stopPath : nil)
    }
    // Persist known diagnostic categories, never arbitrary receipt/payload text.
    private static func failureSummary(action: WakeRequest.Action, message: String) -> String {
        guard action == .prepareResponseStop || action == .stopResponse else { return "Command failed" }
        if message.range(of: #"^Stop window check failed: (focused window|window document) \(AX -?[0-9]+\)$"#, options: .regularExpression) != nil {
            return message
        }
        switch message {
        case "Cannot identify one running Codex app": return "Cannot identify one running Codex app"
        case "Bring the intended Codex chat forward before stopping": return "Codex was not in front"
        case "Cannot verify the current Codex run": return "Codex run log not found"
        case "Cannot read the Codex run log": return "Codex run log could not be read"
        case "Open the intended Codex chat window": return "No focused Codex window"
        case "Codex window is unavailable · Stop shortcut cancelled": return "Codex window could not be read"
        case "Enable Accessibility for Trackypady Bridge in System Settings": return "Accessibility permission required"
        case "Could not prepare the Stop shortcut": return "Could not create Escape key events"
        case "Stop shortcut has not been verified · check Setup": return "Stop shortcut not verified · check Setup"
        case "Codex changed · restart Codex to recheck Stop": return "Codex changed · recheck Stop in Setup"
        case "Stop preparation interrupted · scratch again": return "Stop preparation interrupted"
        case "Phone disconnected": return "Phone disconnected"
        default: return "Command failed"
        }
    }

}
