// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit

/// Device-to-device authenticated messages; the QR secret never goes over BLE.
public enum BluetoothPairing {
    public static let maximumFrameBytes=8192
    public static let maximumPayloadBytes=4096
    public static func serviceID(code: String) -> UUID {
        let hash=SHA256.hash(data:Data(("Trackypady-BLE-service-v1:"+TouchPairing.normalized(code)).utf8))
        let b=Array(hash.prefix(16))
        return UUID(uuid:(b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }
    private struct Hello: Codable { let nonce: Data }
    private struct Welcome: Codable { let phoneNonce: Data;let macNonce: Data }
    private static func master(_ code: String) throws -> SymmetricKey {
        let value=TouchPairing.normalized(code)
        guard value.count == 24,value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else { throw BluetoothProtocolError.invalid }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial:SymmetricKey(data:Data(value.utf8)),salt:Data("Trackypady-BLE-v1".utf8),info:Data("bootstrap".utf8),outputByteCount:32)
    }
    private static func nonce() -> Data { Data((0..<32).map { _ in UInt8.random(in:0...255) }) }
    private static func seal<T:Encodable>(_ value:T,kind:UInt8,code:String) throws -> Data {
        let sealed=try AES.GCM.seal(JSONEncoder().encode(value),using:master(code),authenticating:Data([kind]))
        guard let combined=sealed.combined else { throw BluetoothProtocolError.invalid }
        return Data([kind])+combined
    }
    private static func open<T:Decodable>(_ type:T.Type,packet:Data,kind:UInt8,code:String) throws -> T {
        guard packet.first == kind,packet.count <= maximumFrameBytes else { throw BluetoothProtocolError.invalid }
        return try JSONDecoder().decode(type,from:AES.GCM.open(AES.GCM.SealedBox(combined:packet.dropFirst()),using:master(code),authenticating:Data([kind])))
    }
    public static func hello(code:String) throws -> (nonce:Data,packet:Data) {
        let n=nonce();return (n,try seal(Hello(nonce:n),kind:1,code:code))
    }
    public static func welcome(to packet:Data,code:String) throws -> (session:BluetoothSession,packet:Data) {
        let hello=try open(Hello.self,packet:packet,kind:1,code:code)
        guard hello.nonce.count == 32 else { throw BluetoothProtocolError.invalid }
        let n=nonce()
        return (try BluetoothSession(master:master(code),phoneNonce:hello.nonce,macNonce:n,phone:false),
                try seal(Welcome(phoneNonce:hello.nonce,macNonce:n),kind:2,code:code))
    }
    public static func finish(packet:Data,code:String,phoneNonce:Data) throws -> BluetoothSession {
        let welcome=try open(Welcome.self,packet:packet,kind:2,code:code)
        guard welcome.phoneNonce == phoneNonce,welcome.macNonce.count == 32 else { throw BluetoothProtocolError.invalid }
        return try BluetoothSession(master:master(code),phoneNonce:phoneNonce,macNonce:welcome.macNonce,phone:true)
    }
    public static func frame(_ packet:Data) throws -> Data {
        guard !packet.isEmpty,packet.count <= maximumFrameBytes else { throw BluetoothProtocolError.invalid }
        var count=UInt32(packet.count).bigEndian
        return withUnsafeBytes(of:&count) { Data($0) }+packet
    }
}

public enum BluetoothProtocolError: Error { case invalid }
public struct BluetoothSession {
    private struct Message: Codable { let sequence:UInt64;let payload:Data }
    private let outbound:SymmetricKey
    private let inbound:SymmetricKey
    private var sent:UInt64=0
    private var received:UInt64=0
    fileprivate init(master:SymmetricKey,phoneNonce:Data,macNonce:Data,phone:Bool) throws {
        func key(_ label:String)->SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial:master,salt:phoneNonce+macNonce,info:Data(label.utf8),outputByteCount:32)
        }
        outbound=key(phone ? "phone-to-mac" : "mac-to-phone")
        inbound=key(phone ? "mac-to-phone" : "phone-to-mac")
    }
    public mutating func seal(_ payload:Data) throws -> Data {
        guard !payload.isEmpty,payload.count <= BluetoothPairing.maximumPayloadBytes,sent < UInt64.max else { throw BluetoothProtocolError.invalid }
        let sequence=sent+1
        let data=try JSONEncoder().encode(Message(sequence:sequence,payload:payload))
        let sealed=try AES.GCM.seal(data,using:outbound,authenticating:Data([3]))
        guard let combined=sealed.combined else { throw BluetoothProtocolError.invalid }
        sent=sequence;return Data([3])+combined
    }
    public mutating func open(_ packet:Data) throws -> Data {
        guard packet.first == 3,packet.count <= BluetoothPairing.maximumFrameBytes,received < UInt64.max else { throw BluetoothProtocolError.invalid }
        let plain=try AES.GCM.open(AES.GCM.SealedBox(combined:packet.dropFirst()),using:inbound,authenticating:Data([3]))
        let value=try JSONDecoder().decode(Message.self,from:plain)
        guard value.sequence == received+1,!value.payload.isEmpty,value.payload.count <= BluetoothPairing.maximumPayloadBytes else { throw BluetoothProtocolError.invalid }
        received=value.sequence;return value.payload
    }
}

public struct BluetoothFrameDecoder {
    private var buffer=Data()
    public init() {}
    public mutating func append(_ data:Data) throws -> [Data] {
        guard buffer.count+data.count <= (BluetoothPairing.maximumFrameBytes+4)*2 else { throw BluetoothProtocolError.invalid }
        buffer.append(data)
        var packets:[Data]=[]
        while buffer.count >= 4 {
            let count=Int(buffer.prefix(4).withUnsafeBytes { UInt32(bigEndian:$0.loadUnaligned(as:UInt32.self)) })
            guard count>0,count<=BluetoothPairing.maximumFrameBytes else { throw BluetoothProtocolError.invalid }
            guard buffer.count >= count+4 else { break }
            packets.append(Data(buffer.dropFirst(4).prefix(count)))
            buffer=Data(buffer.dropFirst(count+4))
        }
        return packets
    }
}
