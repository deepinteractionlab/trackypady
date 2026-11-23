// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import CoreGraphics

enum MacModifierState {
    /// Flags can retain the chord on a synthesized non-modifier event even when
    /// none of the modifier keys is down. Check both sides of each actual key.
    static var hasPressedKeys: Bool {
        let keys: [CGKeyCode]=[59,62,58,61,56,60,55,54]
        return keys.contains { CGEventSource.keyState(.combinedSessionState,key:$0) }
    }
}
