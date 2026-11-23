// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Security

public struct PairedPhone: Codable, Equatable, Sendable {
    public let installation: UUID
    public let name: String
    public let pairedAt: Date

    public init(installation: UUID, name: String, pairedAt: Date) {
        self.installation = installation
        self.name = name
        self.pairedAt = pairedAt
    }
}

public struct SavedTouchPairing: Codable,Equatable,Sendable {
    public let name: String
    public let code: String
    public let peripheralID: UUID?
    public let phone: PairedPhone?
    public var prefersWiFi: Bool?
    private let forgotten: [RevocationNotice]?
    public var notices: [RevocationNotice] { forgotten ?? [] }
    public init(code: String, peripheralID: UUID? = nil, phone: PairedPhone? = nil, notices: [RevocationNotice] = []) throws {
        let parsed=try TouchPairing.parseQR(TouchPairing.qrPayload(code:code))
        self.name=parsed.name;self.code=parsed.code;self.peripheralID=peripheralID;self.phone=phone
        forgotten = notices.isEmpty ? nil : notices
    }
    public func validated() throws -> SavedTouchPairing {
        var value=try SavedTouchPairing(code:code, peripheralID:peripheralID, phone:phone, notices:notices)
        value.prefersWiFi = prefersWiFi
        guard name == value.name else { throw CocoaError(.coderReadCorrupt) }
        return value
    }
}

/// Device-local Keychain storage. Pairing secrets are never written to preferences or logs.
public struct TouchPairingStore: Sendable {
    public enum Role: String,Sendable { case bridge,phone }
    private let namespace: String
    public init(namespace: String="org.example.trackypady.local.pairing.v1") { self.namespace=namespace }
    private func query(_ role: Role) -> [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:namespace,kSecAttrAccount as String:role.rawValue]
    }
    private struct StoreError: LocalizedError {
        let operation: String
        let status: OSStatus
        var errorDescription: String? { "Could not \(operation) saved pairing (Keychain \(status))." }
    }
    private func data(for role: Role) throws -> Data? {
        var search=query(role)
        search[kSecReturnData as String]=true;search[kSecMatchLimit as String]=kSecMatchLimitOne
        var value: CFTypeRef?
        let result=SecItemCopyMatching(search as CFDictionary,&value)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess else { throw StoreError(operation:"read",status:result) }
        guard let data=value as? Data else { throw CocoaError(.coderReadCorrupt) }
        return data
    }
    private func write(_ data: Data, for role: Role) throws {
        let search=query(role),changes=[kSecValueData as String:data]
        var result=SecItemUpdate(search as CFDictionary,changes as CFDictionary)
        if result == errSecItemNotFound {
            var item=search;item[kSecValueData as String]=data
            #if os(iOS)
            item[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            #endif
            result=SecItemAdd(item as CFDictionary,nil)
        }
        guard result == errSecSuccess else { throw StoreError(operation:"save",status:result) }
    }

    private struct PhoneRecord: Codable {
        var active: SavedTouchPairing?
        var pendingForgets: [SavedTouchPairing] = []
    }

    private func phoneRecord() throws -> PhoneRecord {
        guard let data = try data(for: .phone) else { return PhoneRecord() }
        let decoder = JSONDecoder()
        if let record = try? decoder.decode(PhoneRecord.self, from: data) {
            return try PhoneRecord(active: record.active?.validated(), pendingForgets: record.pendingForgets.map { try $0.validated() })
        }
        return try PhoneRecord(active: decoder.decode(SavedTouchPairing.self, from: data).validated())
    }

    private func savePhoneRecord(_ record: PhoneRecord) throws {
        if record.active == nil && record.pendingForgets.isEmpty { try delete(.phone) }
        else { try write(JSONEncoder().encode(record), for: .phone) }
    }

    public func load(_ role: Role) throws -> SavedTouchPairing? {
        if role == .phone { return try phoneRecord().active }
        guard let data = try data(for: role) else { return nil }
        return try JSONDecoder().decode(SavedTouchPairing.self, from: data).validated()
    }

    public func save(_ pairing: SavedTouchPairing, for role: Role) throws {
        let value = try pairing.validated()
        if role == .phone {
            var record = try phoneRecord()
            record.active = value
            try savePhoneRecord(record)
        } else {
            try write(JSONEncoder().encode(value), for: role)
        }
    }

    /// Remove control access and preserve outstanding delivery in one device-local Keychain write.
    public func queuePhoneForget(_ pairing: SavedTouchPairing) throws {
        var record = try phoneRecord()
        if !record.pendingForgets.contains(where: { $0.code == pairing.code }) {
            record.pendingForgets.append(try pairing.validated())
        }
        if record.active?.code == pairing.code { record.active = nil }
        try savePhoneRecord(record)
    }

    public func pendingPhoneForgets() throws -> [SavedTouchPairing] { try phoneRecord().pendingForgets }

    public func confirmPhoneForget(code: String) throws {
        var record = try phoneRecord()
        record.pendingForgets.removeAll { $0.code == code }
        try savePhoneRecord(record)
    }
    /// Revoke the previous bridge credential by replacing it in place.
    /// The macOS login keychain can allow updates to item data while denying deletion.
    public func rotateBridgePairing() throws -> SavedTouchPairing {
        let previous = try load(.bridge)
        var notices = previous?.notices ?? []
        if let previous { notices.append(RevocationNotice(code: previous.code)) }
        let replacement = try SavedTouchPairing(code: TouchPairing.code(), notices: notices)
        try save(replacement, for: .bridge)
        return replacement
    }

    public func forget(_ role: Role) throws {
        if role == .phone {
            var record = try phoneRecord()
            record.active = nil
            try savePhoneRecord(record)
        } else { try delete(role) }
    }

    private func delete(_ role: Role) throws {
        let result=SecItemDelete(query(role) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw StoreError(operation:"forget",status:result) }
    }
}
