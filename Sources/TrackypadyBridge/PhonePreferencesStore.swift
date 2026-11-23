// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation
import TouchCore

/// The first upgraded phone seeds an unconfigured Mac. Subsequent connections only acknowledge.
struct PhonePreferencesStore {
    let defaults: UserDefaults
    private let key = "phonePreferences"

    var saved: PhonePreferences? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(PhonePreferences.self, from: $0) }
    }

    func save(_ value: PhonePreferences) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    func initialValue(reportedBy phone: PhonePreferences) -> PhonePreferences {
        if let saved { return saved }
        save(phone)
        return phone
    }
}
