// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
/// Semantic feedback from the phone. Gesture thresholds, Bluetooth receipts and
/// haptic timing belong to the phone; artwork and playback belong to the skin.
public enum PhoneSkinEvent: Sendable {
    case steer, queueHoldBegan, queueCommitted, queueHoldEnded, sendFailed
    case stopped(ScratchGesture.Direction)
    case draftInput(DiscardInputAcknowledgement.Action), draftFailed, selectionCleared
    case recordingError, recordingAcknowledged, reset
}
