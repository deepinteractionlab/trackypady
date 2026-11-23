// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import SwiftUI

struct HapticMappingEditor: View {
    @ObservedObject var model: BridgeModel

    private var hapticsEnabled: Binding<Bool> {
        Binding(
            get: { !model.phonePreferences.hapticsDisabled },
            set: { model.phonePreferences.hapticsDisabled = !$0 }
        )
    }

    var body: some View {
        Form {
            Section("Settings") {
                Toggle(isOn: hapticsEnabled) {
                    settingLabel("All haptic feedback",
                                 detail: "Turn off to mute all Trackypady vibrations on your iPhone.")
                }
                Toggle(isOn: $model.phonePreferences.recordingHapticsEnabled) {
                    settingLabel("Haptic feedback for dictation",
                                 detail: "Feel when dictation starts and while it records.")
                }
                .disabled(model.phonePreferences.hapticsDisabled)
            }
        }
        .formStyle(.grouped)
    }

    private func settingLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
