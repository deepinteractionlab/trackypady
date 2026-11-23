// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Sent inside an authenticated channel so a newer launch of the same app can retire its old socket.
public struct PhoneConnectionAttempt: Codable, Sendable, Equatable {
    public let installation: UUID
    public let sequence: UInt64
    public var deviceName: String?
    /// A release-only handshake from the installation that originally paired.
    public var requestsForget: Bool?
    public init(installation: UUID, sequence: UInt64, deviceName: String? = nil) {
        self.deviceName = deviceName
        self.installation = installation
        self.sequence = sequence
    }
}

public enum WiFiSetupAction: String, Codable, Sendable {
    case tryWiFi, openAppSettings, useBluetooth
}

public struct WiFiFailureReport: Codable, Sendable, Equatable {
    public let id: UUID
    /// Receipt that requested this switch; automatic reconnects have no request.
    public let requestID: UUID?
    public let localNetworkDenied: Bool
    public init(localNetworkDenied: Bool, requestID: UUID? = nil) {
        id = UUID()
        self.requestID = requestID
        self.localNetworkDenied = localNetworkDenied
    }
}

public struct WakeRequest: Codable,Sendable,Equatable {
    public enum Action: String,Codable,Sendable { case wakeCodex,startDictation,stopDictation,dictationHeartbeat,getStatus,sendSteering,sendQueue,discardDraft,prepareResponseStop,stopResponse }
    public let version: Int
    public let id: UUID
    public var supportsRouteSwitch: Bool?
    public var prefersWiFi: Bool?
    public var wifiFailure: WiFiFailureReport?
    public var routeSwitchFailed: Bool?
    public var supportsWiFiSetup: Bool?
    public var wifiSetupFellBack: Bool?
    public var connectionAttempt: PhoneConnectionAttempt?
    public let action: Action
    public let appliedPhonePreferences: PhonePreferences?
    public let appliedScratchTiming: ScratchTiming?
    public let lastScratchTrial: String?
    public let scratchID: UUID?
    public let recordingID: UUID?
    public let hapticPreview: HapticPreviewState?
    public let hapticMappingRevision: UUID?
    public init(id: UUID=UUID(),action: Action = .wakeCodex,recordingID: UUID?=nil,scratchID: UUID?=nil,hapticPreview: HapticPreviewState?=nil,hapticMappingRevision: UUID?=nil,appliedScratchTiming: ScratchTiming?=nil,lastScratchTrial: String?=nil,appliedPhonePreferences: PhonePreferences?=nil) {
        self.appliedPhonePreferences = appliedPhonePreferences
        self.appliedScratchTiming = appliedScratchTiming
        self.lastScratchTrial = lastScratchTrial
        self.scratchID=scratchID; self.version=1; self.id=id; self.action=action; self.recordingID=recordingID;self.hapticPreview=hapticPreview;self.hapticMappingRevision=hapticMappingRevision
    }
}
public struct WakeReceipt: Codable,Sendable,Equatable {
    public enum Outcome: String,Codable,Sendable { case foreground,dictationRecording,dictationStopped,failed,status,steeringSent,queueSent,draftSelected,draftDiscarded,draftEditRequested,stopPrepared,noActiveResponse,stopPressed }
    public let version: Int
    public let id: UUID
    public var wifiSetupAction: WiFiSetupAction?
    public let outcome: Outcome
    public let message: String
    public enum FailureReason: String, Codable, Sendable { case composerFocus, other }
    public let failureReason: FailureReason?
    public let phonePreferences: PhonePreferences?
    public let dictateAfterStop: Bool?
    public let scratchTiming: ScratchTiming?
    public let status: BridgeStatus?
    public let hapticPreview: HapticPreviewCommand?
    public let hapticMapping: HapticMapping?
    public init(id: UUID,outcome: Outcome,message: String,status: BridgeStatus?=nil,hapticPreview: HapticPreviewCommand?=nil,hapticMapping: HapticMapping?=nil,scratchTiming: ScratchTiming?=nil,dictateAfterStop: Bool?=nil,phonePreferences: PhonePreferences?=nil,failureReason: FailureReason?=nil) {
        self.failureReason = failureReason
        self.phonePreferences = phonePreferences
        self.dictateAfterStop = dictateAfterStop
        self.scratchTiming = scratchTiming
        self.version=1; self.id=id; self.outcome=outcome; self.message=message;self.status=status;self.hapticPreview=hapticPreview;self.hapticMapping=hapticMapping
    }
}
extension WakeReceipt {
    public var isComposerFocusFailure: Bool {
        if let failureReason { return failureReason == .composerFocus }
        return outcome == .failed && message == TouchPresentation.swipeFocusWarning
    }

    public enum SubmissionResult { case dispatched, legacyUnconfirmed, failed }

    /// Some earlier v1 bridges reported a posted shortcut with a failed receipt
    /// when they could not confirm the resulting edit in Codex.
    public func submissionResult(for action: WakeRequest.Action) -> SubmissionResult {
        switch (action, outcome) {
        case (.sendQueue, .queueSent), (.sendSteering, .steeringSent): return .dispatched
        case (.sendQueue, .failed) where message.hasPrefix("Queue command sent"),
             (.sendSteering, .failed) where message.hasPrefix("Steering command sent"):
            return .legacyUnconfirmed
        default: return .failed
        }
    }
}

/// Session-local bounded deduplication, including overlapping deliveries.
/// The client never automatically retries uncertain actions.
public actor WakeService {
    private var results: [UUID:WakeReceipt]=[:]
    private var requests: [UUID:WakeRequest]=[:]
    private var pending: [UUID:Task<WakeReceipt,Never>]=[:]
    private var order: [UUID]=[]
    private let activate: @Sendable (WakeRequest) async -> WakeReceipt
    public init(activate: @escaping @Sendable (WakeRequest) async -> WakeReceipt) { self.activate=activate }
    public func handle(_ request: WakeRequest) async -> WakeReceipt {
        guard request.version == 1 else { return WakeReceipt(id:request.id,outcome:.failed,message:"Unsupported command version") }
        if request.action == .getStatus { return await activate(request) }
        switch request.action {
        case .prepareResponseStop, .stopResponse:
            guard request.scratchID != nil else { return WakeReceipt(id:request.id,outcome:.failed,message:"Missing scratch identity") }
        case .startDictation, .stopDictation, .dictationHeartbeat:
            guard request.recordingID != nil else { return WakeReceipt(id:request.id,outcome:.failed,message:"Dictation requires a recording identity") }
        default: break
        }
        if let original=requests[request.id],original != request {
            return WakeReceipt(id:request.id,outcome:.failed,message:"Event identity was reused for a different command")
        }
        if let result=results[request.id] { return result }
        if let task=pending[request.id] { return await task.value }
        requests[request.id]=request
        let activate=self.activate
        let task=Task { await activate(request) }; pending[request.id]=task
        let receipt=await task.value
        pending[request.id]=nil; results[request.id]=receipt; order.append(request.id)
        if order.count > 256 { let old=order.removeFirst();results[old]=nil;requests[old]=nil }
        return receipt
    }
}
