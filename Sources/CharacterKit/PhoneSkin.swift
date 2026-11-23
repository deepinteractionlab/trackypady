// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import TouchCore

@MainActor
public protocol PhoneSkin: ObservableObject {
    associatedtype Character: View
    var background: Color { get }
    var ink: Color { get }
    func handle(_ event: PhoneSkinEvent)
    @ViewBuilder func character(recording: Bool, playing: Bool) -> Character
}
