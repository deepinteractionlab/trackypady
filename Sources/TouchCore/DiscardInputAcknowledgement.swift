// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Reports the resolved input intent before editing, independently of result confirmation.
public struct DiscardInputAcknowledgement: Codable,Sendable,Equatable {
    public enum Kind: String,Codable,Sendable { case discardInput }
    public enum Action: String,Codable,Sendable {
        case selecting,discarding
        public var moment: HapticMoment { self == .selecting ? .draftSelected : .draftDiscarded }
    }
    public let version: Int
    public let kind: Kind
    public let requestID: UUID
    public let action: Action
    public init(requestID: UUID,action: Action) {
        version=1;kind = .discardInput;self.requestID=requestID;self.action=action
    }
}

public struct DiscardInputFeedback: Sendable {
    private var requestID: UUID?
    public private(set) var action: DiscardInputAcknowledgement.Action?
    public init() {}
    public mutating func begin(_ id: UUID) { requestID=id;action=nil }
    public mutating func receive(_ input: DiscardInputAcknowledgement) -> HapticMoment? {
        guard input.version == 1,input.requestID == requestID,action == nil else { return nil }
        action=input.action;return input.action.moment
    }
    public mutating func reset() { requestID=nil;action=nil }
}
