// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
@preconcurrency import Network
import Foundation
import TouchCore

public enum TouchWire {
    public static let maximumBytes=4096
    public static func packet<T: Encodable>(_ value: T) throws -> Data {
        let data=try JSONEncoder().encode(value)
        guard !data.isEmpty,data.count <= maximumBytes else { throw CocoaError(.coderInvalidValue) }
        var count=UInt32(data.count).bigEndian
        var packet=withUnsafeBytes(of:&count) { Data($0) }; packet.append(data); return packet
    }
    private static func exact(_ connection: NWConnection,count: Int,completion: @escaping @Sendable (Data?)->Void) {
        connection.receive(minimumIncompleteLength:count,maximumLength:count) { data,_,_,error in
            guard error == nil,let data,data.count == count else { completion(nil); return }
            completion(data)
        }
    }
    public static func receive<T: Decodable & Sendable>(_ type: T.Type,from connection: NWConnection,
        completion: @escaping @Sendable (T?)->Void) {
        exact(connection,count:4) { header in
            guard let header else { completion(nil); return }
            let count=Int(header.withUnsafeBytes { UInt32(bigEndian:$0.loadUnaligned(as:UInt32.self)) })
            guard count > 0,count <= maximumBytes else { completion(nil); return }
            exact(connection,count:count) { data in
                guard let data else { completion(nil); return }
                completion(try? JSONDecoder().decode(type,from:data))
            }
        }
    }
}

public final class TouchServer: @unchecked Sendable {
    private let queue=DispatchQueue(label:"com.deepinteractionlab.trackypady.server")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var generation=UUID()
    private var inactivityTimer: DispatchWorkItem?
    private let inactivityTimeout: TimeInterval
    public var onPort: @Sendable (UInt16)->Void = { _ in }
    private let onState: @Sendable (String)->Void
    private let onRequest: @Sendable (WakeRequest,@escaping @Sendable (WakeReceipt)->Void)->Void
    public init(onState: @escaping @Sendable (String)->Void,
        onRequest: @escaping @Sendable (WakeRequest,@escaping @Sendable (WakeReceipt)->Void)->Void,
        inactivityTimeout: TimeInterval=8) {
        self.onState=onState; self.onRequest=onRequest; self.inactivityTimeout=inactivityTimeout
    }
    public func start(code: String,loopbackOnly: Bool=false) {
        queue.async { [self] in
            stopOnQueue(); let id=generation
            do {
                let parameters=try TouchPairing.parameters(code:code,loopbackOnly:loopbackOnly,allowEthernet:true)
                if loopbackOnly { parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any) }
                let listener=try NWListener(using:parameters); self.listener=listener
                if !loopbackOnly { listener.service=NWListener.Service(name:TouchPairing.serviceName(code:code),type:TouchPairing.service) }
                listener.stateUpdateHandler = { [weak self,weak listener] state in
                    guard let self,self.generation == id else { return }
                    switch state {
                    case .ready: if let port=listener?.port { self.onPort(port.rawValue) }; self.onState("Ready to pair")
                    case .failed(let error): self.onState(error.localizedDescription); self.stopOnQueue()
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self,self.generation == id,self.connection == nil else { connection.cancel(); return }
                    self.connection=connection
                    connection.stateUpdateHandler = { [weak self,weak connection] state in
                        guard let self,let connection,self.generation == id,self.connection === connection else { return }
                        switch state {
                        case .ready:
                            self.onState("iPhone connected")
                            self.armInactivityTimeout(connection,id:id)
                            self.receive(connection,id:id)
                        case .failed,.cancelled,.waiting: self.disconnect(connection,id:id)
                        default: break
                        }
                    }
                    connection.start(queue:self.queue)
                    self.queue.asyncAfter(deadline:.now()+8) { [weak self,weak connection] in
                        guard let self,let connection,self.connection === connection,connection.state != .ready else { return }
                        connection.cancel()
                    }
                }
                listener.start(queue:queue)
            } catch { onState(error.localizedDescription) }
        }
    }
    private func receive(_ connection: NWConnection,id: UUID) {
        TouchWire.receive(WakeRequest.self,from:connection) { [weak self,weak connection] request in
            guard let self,let connection,self.generation == id,self.connection === connection else { return }
            guard let request else { self.disconnect(connection,id:id); return }
            self.armInactivityTimeout(connection,id:id)
            self.onRequest(request) { [weak self,weak connection] receipt in
                guard let self,let connection else { return }
                self.queue.async { [self,connection] in
                    guard self.generation == id,self.connection === connection else { return }
                    do {
                        let data=try TouchWire.packet(receipt)
                        connection.send(content:data,completion:.contentProcessed { [weak self,weak connection] error in
                            guard let self,let connection,self.generation == id,self.connection === connection else { return }
                            guard error == nil else { self.disconnect(connection,id:id); return }
                            self.armInactivityTimeout(connection,id:id)
                            self.receive(connection,id:id)
                        })
                    } catch { self.disconnect(connection,id:id) }
                }
            }
        }
    }
    private func armInactivityTimeout(_ connection: NWConnection,id: UUID) {
        inactivityTimer?.cancel()
        let timer=DispatchWorkItem { [weak self,weak connection] in
            guard let self,let connection else { return }
            self.disconnect(connection,id:id)
        }
        inactivityTimer=timer
        queue.asyncAfter(deadline:.now()+inactivityTimeout,execute:timer)
    }
    private func disconnect(_ connection: NWConnection,id: UUID) {
        guard generation == id,self.connection === connection else { return }
        inactivityTimer?.cancel();inactivityTimer=nil
        // Free the slot now, rather than waiting for a cancellation state callback.
        self.connection=nil;connection.stateUpdateHandler=nil;connection.cancel()
        onState("iPhone disconnected · ready to pair")
    }
    public func stop() { queue.async { [self] in stopOnQueue(); onState("Bridge stopped") } }
    private func stopOnQueue() {
        generation=UUID();inactivityTimer?.cancel();inactivityTimer=nil
        connection?.stateUpdateHandler=nil;connection?.cancel();connection=nil;listener?.cancel();listener=nil
    }
}

public final class TouchClient: @unchecked Sendable {
    private let queue=DispatchQueue(label:"com.deepinteractionlab.trackypady.client")
    private var connection: NWConnection?
    private var ready=false
    private var pending: UUID?
    private let onState: @Sendable (String,Bool)->Void
    private let onReceipt: @Sendable (WakeReceipt)->Void
    public init(onState: @escaping @Sendable (String,Bool)->Void,onReceipt: @escaping @Sendable (WakeReceipt)->Void) {
        self.onState=onState; self.onReceipt=onReceipt
    }
    public func connect(endpoint: NWEndpoint,code: String,loopbackOnly: Bool=false) {
        queue.async { [self] in
            stopOnQueue()
            do {
                let connection=NWConnection(to:endpoint,using:try TouchPairing.parameters(code:code,loopbackOnly:loopbackOnly)); self.connection=connection
                connection.stateUpdateHandler = { [weak self,weak connection] state in
                    guard let self,let connection,self.connection === connection else { return }
                    switch state {
                    case .ready: self.ready=true; self.onState("Connected to Mac",true)
                    case .failed(let error): self.fail("Connection failed: \(error.localizedDescription)")
                    case .cancelled: self.fail("Disconnected")
                    case .waiting: self.onState("Waiting for Mac · connect both devices to the same Wi-Fi",false)
                    default: break
                    }
                }
                connection.start(queue:queue)
                queue.asyncAfter(deadline:.now()+8) { [weak self,weak connection] in
                    guard let self,let connection,self.connection === connection,!self.ready else { return }
                    self.fail("Pairing timed out · scan the current Mac QR")
                }
            } catch { onState(error.localizedDescription,false) }
        }
    }
    public func send(_ request: WakeRequest=WakeRequest()) {
        queue.async { [self] in
            guard ready,let connection,pending == nil else { return }
            do {
                let data=try TouchWire.packet(request); pending=request.id
                if request.action != .getStatus { onState("Request sent · waiting for Mac",true) }
                connection.send(content:data,completion:.contentProcessed { [weak self,weak connection] error in
                    guard let self,let connection,self.connection === connection else { return }
                    guard error == nil else { self.fail("Delivery uncertain · reconnect before trying again"); return }
                    TouchWire.receive(WakeReceipt.self,from:connection) { [weak self,weak connection] receipt in
                        guard let self,let connection,self.connection === connection else { return }
                        guard let receipt,receipt.id == request.id,receipt.version == 1 else { self.fail("Result unavailable · action not retried"); return }
                        self.pending=nil; self.onReceipt(receipt); self.onState("Connected to Mac",true)
                    }
                })
                queue.asyncAfter(deadline:.now()+(request.action == .startDictation ? 8 : 5)) { [weak self,weak connection] in
                    guard let self,let connection,self.connection === connection,self.pending == request.id else { return }
                    self.fail("Mac result timed out · action not retried")
                }
            } catch { fail("Could not encode wake action") }
        }
    }
    public func stop() { queue.async { [self] in stopOnQueue(); onState("Disconnected",false) } }
    private func fail(_ message: String) { stopOnQueue(); onState(message,false) }
    private func stopOnQueue() { ready=false; pending=nil; connection?.stateUpdateHandler=nil; connection?.cancel(); connection=nil }
}
