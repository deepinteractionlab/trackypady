// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Use the editor's current selection, rather than an internal armed/unarmed flag.
public enum DiscardSelection {
    public enum Action { case selectAll,deleteSelection }
    public static func action(textUTF16Length: Int,location: Int,length: Int) -> Action? {
        guard textUTF16Length>0,location>=0,length>=0,location<=textUTF16Length,
              length<=textUTF16Length-location else { return nil }
        return length>0 ? .deleteSelection : .selectAll
    }
    /// Chromium can expose a terminal paragraph break beyond the selectable text.
    public static func isComplete(text: String,location: Int,length: Int) -> Bool {
        guard location == 0,action(textUTF16Length:text.utf16.count,location:location,length:length) == .deleteSelection else { return false }
        let remainder=(text as NSString).substring(from:length)
        return remainder.trimmingCharacters(in:.newlines).isEmpty
    }
    public static func matchesAfterDelete(observed: String,expected: String) -> Bool {
        observed == expected || (observed.trimmingCharacters(in:.newlines).isEmpty && expected.trimmingCharacters(in:.newlines).isEmpty)
    }

}

/// Ties a swipe that started during selection to that specific edit, even if
/// the Bluetooth receipt arrives before the user lifts their fingers.
public struct DiscardGestureGate {
    public private(set) var pendingID: UUID?
    private var selectedID: UUID?
    private var buffered = false

    public init() {}

    public mutating func begin(_ id: UUID) {
        pendingID = id
        selectedID = nil
        buffered = false
    }

    public mutating func repeatDown(during id: UUID) -> Bool {
        if pendingID == id {
            buffered = true
            return false
        }
        guard selectedID == id else { return false }
        selectedID = nil
        return true
    }

    public mutating func finish(_ id: UUID, selected: Bool) -> Bool {
        guard pendingID == id else { return false }
        pendingID = nil
        selectedID = selected && !buffered ? id : nil
        defer { buffered = false }
        return buffered && selected
    }
}
