// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
/// Native hold-to-dictate starts a fresh recording in both idle and retry states.
/// A Retry button is a terminal transcription error, never an instruction to click it.
public enum DictationReadiness {
    public static let startLabels: Set<String>=["Dictate","Start dictation","Retry dictation"]
    public static let busyLabels: Set<String>=["Stop dictation","Cancel transcription","Cancel dictation","Preparing dictation","Finishing dictation","Starting dictation; click to cancel"]
    public static func canStart(allLabels: Set<String>,enabledLabels: Set<String>) -> Bool {
        allLabels.isDisjoint(with:busyLabels) && !enabledLabels.isDisjoint(with:startLabels)
    }
}
