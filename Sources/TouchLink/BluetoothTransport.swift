// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
@preconcurrency import CoreBluetooth
import Foundation
import TouchCore

private enum BLECharacteristics {
    static let forgetService = CBUUID(string: "2D36B7D8-120A-48DD-89EA-F139BE0D5F97")
    static let request=CBUUID(string:"5E750504-6AA7-49C2-9484-CB297D280301")
    static let receipt=CBUUID(string:"5E750504-6AA7-49C2-9484-CB297D280302")
}

public enum BridgeConnectionState: Equatable, Sendable {
    case starting, advertising, connected, disconnected, stopped
    case bluetoothPoweredOff, bluetoothUnauthorized
    case unavailable(String)

    public var message: String {
        switch self {
        case .starting: return "Starting Bluetooth…"
        case .advertising: return "Ready to pair over Bluetooth"
        case .connected: return "iPhone connected"
        case .disconnected: return "iPhone disconnected · ready to pair"
        case .stopped: return "Bridge stopped"
        case .bluetoothPoweredOff: return "Bluetooth is off · turn it on to connect"
        case .bluetoothUnauthorized: return "Bluetooth permission is required for Trackypady Bridge"
        case let .unavailable(message): return message
        }
    }
}

struct BluetoothPairingRevocation: Codable {
    let pairingRevocationVersion: Int

    init() { pairingRevocationVersion = 1 }
}

/// Mac peripheral. Only authenticated session messages reach the existing action handler.
@MainActor
public final class BluetoothTouchServer: NSObject,@preconcurrency CBPeripheralManagerDelegate {
    private lazy var manager=CBPeripheralManager(delegate:self,queue:nil)
    private let onState: @MainActor (BridgeConnectionState) -> Void
    private let onRadioPowerOffChanged: @MainActor (Bool) -> Void
    private let onRequest:@MainActor (WakeRequest,@escaping @Sendable (WakeReceipt)->Void)->Void
    private var code:String?
    private var notices: [RevocationNotice] = []
    private var service:CBMutableService?
    private var output:CBMutableCharacteristic?
    private var peer:CBCentral?
    private var subscribed:Set<UUID>=[]
    private var session:BluetoothSession?
    private var decoder=BluetoothFrameDecoder()
    private var outgoing=Data()
    private var timeout:Task<Void,Never>?
    private var generation=UUID()
    public var connectedSessionID: UUID? { session == nil ? nil : generation }
    public init(onConnectionState: @escaping @MainActor (BridgeConnectionState) -> Void,
                onRadioPowerOffChanged: @escaping @MainActor (Bool) -> Void = { _ in },
                onRequest:@escaping @MainActor (WakeRequest,@escaping @Sendable (WakeReceipt)->Void)->Void) {
        self.onRadioPowerOffChanged = onRadioPowerOffChanged
        self.onState=onConnectionState;self.onRequest=onRequest;super.init()
    }

    public convenience init(onState: @escaping @Sendable (String) -> Void,
                            onRequest: @escaping @Sendable (WakeRequest, @escaping @Sendable (WakeReceipt) -> Void) -> Void) {
        self.init(onConnectionState: { onState($0.message) }, onRequest: onRequest)
    }
    public func start(code:String, notices: [RevocationNotice] = []) {
        self.notices = notices
        self.code=TouchPairing.normalized(code)
        onRadioPowerOffChanged(manager.state == .poweredOff)
        if manager.state == .poweredOn { configure() }
        else { reportRadioState() }
    }
    public func stop() {
        code=nil;manager.stopAdvertising();manager.removeAllServices();resetPeer();service=nil;output=nil
        onState(.stopped)
    }
    func retirePairing() -> Bool {
        // Keep the authenticated notification path open while rejecting further writes.
        code = nil
        manager.stopAdvertising()
        guard peer != nil, session != nil else { return false }
        do {
            let message = try JSONEncoder().encode(BluetoothPairingRevocation())
            guard let packet = try session?.seal(message) else { return false }
            try enqueue(packet)
            return true
        } catch {
            return false
        }
    }
    private func reportRadioState() {
        switch manager.state {
        case .poweredOff:onState(.bluetoothPoweredOff)
        case .unauthorized:onState(.bluetoothUnauthorized)
        case .unsupported:onState(.unavailable("Bluetooth LE is unavailable on this Mac"))
        default:onState(.starting)
        }
    }
    public func peripheralManagerDidUpdateState(_ peripheral:CBPeripheralManager) {
        onRadioPowerOffChanged(peripheral.state == .poweredOff)
        guard code != nil else { return }
        if peripheral.state == .poweredOn { configure() }
        else { resetPeer();reportRadioState() }
    }
    private func configure() {
        guard let code else { return }
        resetPeer();subscribed.removeAll();manager.stopAdvertising();manager.removeAllServices()
        let s=CBMutableService(type:CBUUID(string:BluetoothPairing.serviceID(code:code).uuidString),primary:true)
        let input=CBMutableCharacteristic(type:BLECharacteristics.request,properties:[.write],value:nil,permissions:[.writeable])
        let output=CBMutableCharacteristic(type:BLECharacteristics.receipt,properties:[.notify],value:nil,permissions:[])
        s.characteristics=[input,output];service=s;self.output=output
        if !notices.isEmpty {
            let retired = CBMutableService(type: BLECharacteristics.forgetService, primary: true)
            retired.characteristics = notices.map {
                CBMutableCharacteristic(type: CBUUID(nsuuid: $0.lookup), properties: .read,
                                        value: $0.proof, permissions: .readable)
            }
            manager.add(retired)
        }
        manager.add(s)
    }
    public func peripheralManager(_ peripheral:CBPeripheralManager,didAdd service:CBService,error:Error?) {
        guard code != nil,service.uuid == self.service?.uuid else { return }
        guard error == nil else { onState(.unavailable("Bluetooth service could not start"));return }
        let advertised = notices.isEmpty ? [service.uuid] : [service.uuid, BLECharacteristics.forgetService]
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey:advertised])
    }
    public func peripheralManagerDidStartAdvertising(_ peripheral:CBPeripheralManager,error:Error?) {
        guard code != nil else { return }
        if error != nil { onState(.unavailable("Bluetooth advertising could not start")) }
        else if session == nil { onState(.advertising) }
    }
    public func peripheralManager(_ peripheral:CBPeripheralManager,central:CBCentral,didSubscribeTo characteristic:CBCharacteristic) {
        guard characteristic.uuid == BLECharacteristics.receipt else { return }
        subscribed.insert(central.identifier)
    }
    public func peripheralManager(_ peripheral:CBPeripheralManager,central:CBCentral,didUnsubscribeFrom characteristic:CBCharacteristic) {
        subscribed.remove(central.identifier)
        if peer?.identifier == central.identifier { disconnect() }
    }
    public func peripheralManager(_ peripheral:CBPeripheralManager,didReceiveWrite requests:[CBATTRequest]) {
        guard let first=requests.first else { return }
        // Core Bluetooth treats a delivered write batch as one transaction and
        // requires one response, addressed to its first request.
        guard code != nil,requests.allSatisfy({ request in
            request.central.identifier == first.central.identifier &&
            request.characteristic.uuid == BLECharacteristics.request && request.offset == 0 &&
            subscribed.contains(request.central.identifier) && !(request.value?.isEmpty ?? true) &&
            (peer == nil || peer?.identifier == request.central.identifier)
        }) else { peripheral.respond(to:first,withResult:.unlikelyError);return }
        if peer == nil { peer=first.central;armTimeout() }
        do {
            for request in requests {
                guard let data=request.value else { throw BluetoothProtocolError.invalid }
                for packet in try decoder.append(data) { try receive(packet) }
            }
            peripheral.respond(to:first,withResult:.success)
        } catch { peripheral.respond(to:first,withResult:.unlikelyError);disconnect() }
    }
    private func receive(_ packet:Data) throws {
        guard let code else { throw BluetoothProtocolError.invalid }
        if session == nil {
            let welcome=try BluetoothPairing.welcome(to:packet,code:code)
            session=welcome.session
            try enqueue(welcome.packet)
            armTimeout();onState(.connected)
            return
        }
        guard let data=try session?.open(packet) else { throw BluetoothProtocolError.invalid }
        let request=try JSONDecoder().decode(WakeRequest.self,from:data)
        guard request.version == 1 else { throw BluetoothProtocolError.invalid }
        armTimeout()
        let id=generation
        onRequest(request) { [weak self] receipt in
            Task { @MainActor in
                guard let self,self.generation == id,self.code != nil,self.session != nil else { return }
                do {
                    guard let packet=try self.session?.seal(JSONEncoder().encode(receipt)) else { return }
                    try self.enqueue(packet);self.armTimeout()
                } catch { self.disconnect() }
            }
        }
    }
    private func enqueue(_ packet:Data) throws {
        let frame=try BluetoothPairing.frame(packet)
        guard outgoing.count+frame.count <= BluetoothPairing.maximumFrameBytes+4 else { throw BluetoothProtocolError.invalid }
        outgoing.append(frame);drain()
    }
    public func sendHapticPreview(_ command: HapticPreviewCommand) -> Bool {
        guard session != nil,peer != nil else { return false }
        do {
            guard let packet=try session?.seal(JSONEncoder().encode(HapticPreviewPush(command:command))) else { return false }
            try enqueue(packet);return true
        } catch { disconnect();return false }
    }
    public func sendDiscardInput(_ input: DiscardInputAcknowledgement) -> Bool {
        guard session != nil,peer != nil else { return false }
        do {
            guard let packet=try session?.seal(JSONEncoder().encode(input)) else { return false }
            try enqueue(packet);return true
        } catch { disconnect();return false }
    }
    private func drain() {
        guard let peer,let output,subscribed.contains(peer.identifier) else { return }
        while !outgoing.isEmpty {
            let chunk=Data(outgoing.prefix(peer.maximumUpdateValueLength))
            guard !chunk.isEmpty,manager.updateValue(chunk,for:output,onSubscribedCentrals:[peer]) else { return }
            outgoing.removeFirst(chunk.count)
        }
    }
    public func peripheralManagerIsReady(toUpdateSubscribers peripheral:CBPeripheralManager) { drain() }
    private func armTimeout() {
        timeout?.cancel();let id=generation
        timeout=Task { [weak self] in
            do { try await Task.sleep(for:.seconds(8)) } catch { return }
            guard let self,self.generation == id else { return };self.disconnect()
        }
    }
    private func resetPeer() {
        generation=UUID();timeout?.cancel();timeout=nil;peer=nil;session=nil
        decoder=BluetoothFrameDecoder();outgoing=Data()
    }
    func rejectSession() { disconnect() }
    private func disconnect() { resetPeer();onState(.disconnected) }
}

/// iPhone central. A fresh nonce handshake authenticates the QR-selected Mac.
@MainActor
public final class BluetoothTouchClient: NSObject,@preconcurrency CBCentralManagerDelegate,@preconcurrency CBPeripheralDelegate {
    private lazy var manager=CBCentralManager(delegate:self,queue:nil)
    private let onState:@Sendable (String,Bool)->Void
    private let onReceipt:@Sendable (WakeReceipt)->Void
    private let onPreview:@Sendable (HapticPreviewCommand)->Void
    private let onDiscardInput:@Sendable (DiscardInputAcknowledgement)->Void
    private let onPairingRevoked: @MainActor () -> Void
    private var code:String?
    private var preferredPeripheralID: UUID?
    private var queriedNoticePeers: Set<UUID> = []
    private var usingRetrievedPeripheral = false
    private var discoveryFallback: Task<Void,Never>?
    private let onAuthenticated: @MainActor (String, UUID) -> Void
    private var peripheral:CBPeripheral?
    private var input:CBCharacteristic?
    private var output:CBCharacteristic?
    private var nonce:Data?
    private var session:BluetoothSession?
    private var decoder=BluetoothFrameDecoder()
    private var outgoing=Data()
    private var writing=false
    private var pending:UUID?
    private var timeout:Task<Void,Never>?
    private var connectionTimeout:Task<Void,Never>?
    private var generation=UUID()
    public var isConnecting: Bool { code != nil && session == nil && (peripheral != nil || manager.isScanning) }
    public init(onState:@escaping @Sendable (String,Bool)->Void,onAuthenticated: @escaping @MainActor (String, UUID) -> Void = { _,_ in },onPreview:@escaping @Sendable (HapticPreviewCommand)->Void = { _ in },onDiscardInput:@escaping @Sendable (DiscardInputAcknowledgement)->Void = { _ in },onPairingRevoked: @escaping @MainActor () -> Void = {},onReceipt:@escaping @Sendable (WakeReceipt)->Void) {
        self.onAuthenticated=onAuthenticated;self.onState=onState;self.onReceipt=onReceipt;self.onPreview=onPreview
        self.onDiscardInput=onDiscardInput;self.onPairingRevoked=onPairingRevoked
        super.init()
    }
    public func connect(code:String, peripheralID: UUID? = nil) {
        reset();queriedNoticePeers.removeAll();self.code=TouchPairing.normalized(code);preferredPeripheralID=peripheralID;_=manager
        if manager.state == .poweredOn { beginConnection() } else { reportRadioState() }
    }
    public func stop() { code=nil;reset();onState("Disconnected",false) }
    private func reset() {
        generation=UUID();timeout?.cancel();timeout=nil;connectionTimeout?.cancel();connectionTimeout=nil
        if let peripheral { peripheral.delegate=nil;manager.cancelPeripheralConnection(peripheral) }
        discoveryFallback?.cancel();discoveryFallback=nil;usingRetrievedPeripheral=false
        if manager.state == .poweredOn, manager.isScanning { manager.stopScan() }
        peripheral=nil;input=nil;output=nil;session=nil;nonce=nil
        decoder=BluetoothFrameDecoder();outgoing=Data();writing=false;pending=nil
    }
    private func fail(_ message:String) {
        let retryDiscovery = usingRetrievedPeripheral && session == nil && manager.state == .poweredOn
        reset()
        if retryDiscovery { beginConnection(discoveryOnly: true) }
        else { onState(message,false) }
    }
    private func reportRadioState() {
        switch manager.state {
        case .poweredOff:onState("Bluetooth is off · turn it on to connect",false)
        case .unauthorized:onState("Enable Bluetooth access for Trackypady in Settings",false)
        case .unsupported:onState("Bluetooth LE is unavailable",false)
        default:onState("Starting Bluetooth…",false)
        }
    }
    public func centralManagerDidUpdateState(_ central:CBCentralManager) {
        guard code != nil else { return }
        if central.state == .poweredOn { beginConnection() } else { reset();reportRadioState() }
    }
    private func beginConnection(discoveryOnly: Bool = false) {
        guard let code, peripheral == nil, !manager.isScanning else { return }
        let service = CBUUID(string: BluetoothPairing.serviceID(code: code).uuidString)
        var candidate: CBPeripheral?
        if !discoveryOnly {
            if let preferredPeripheralID {
                candidate = manager.retrievePeripherals(withIdentifiers: [preferredPeripheralID]).first
            }
            if candidate == nil {
                let connected = manager.retrieveConnectedPeripherals(withServices: [service])
                if connected.count == 1 { candidate = connected[0] }
            }
        }
        if let candidate {
            usingRetrievedPeripheral = true
            attach(candidate)
            onState("Reconnecting to your paired Mac…",false)
            // A stale cached address can stay pending in Core Bluetooth. Look for the
            // paired service as well, without interrupting a healthy connection attempt.
            discoveryFallback = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.startDiscovery(service)
            }
        } else { startDiscovery(service) }
        connectionTimeout?.cancel();let id=generation
        connectionTimeout=Task { [weak self] in
            do { try await Task.sleep(for:.seconds(15)) } catch { return }
            guard let self,self.generation == id,self.session == nil else { return }
            self.fail("Bluetooth pairing timed out · keep the Mac nearby and check Bluetooth access")
        }
    }
    private func startDiscovery(_ service: CBUUID) {
        guard manager.state == .poweredOn, !manager.isScanning else { return }
        manager.scanForPeripherals(withServices: [service, BLECharacteristics.forgetService])
        onState("Looking for your Mac over Bluetooth…",false)
    }
    private func attach(_ candidate: CBPeripheral) {
        peripheral=candidate;candidate.delegate=self;manager.connect(candidate)
    }
    public func centralManager(_ central:CBCentralManager,didDiscover candidate:CBPeripheral,advertisementData:[String:Any],rssi RSSI:NSNumber) {
        guard central.isScanning, let code else { return }
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let active = CBUUID(nsuuid: BluetoothPairing.serviceID(code: code))
        if queriedNoticePeers.contains(candidate.identifier), !advertised.contains(active) { return }
        if let peripheral {
            guard usingRetrievedPeripheral, peripheral.identifier != candidate.identifier else { return }
            peripheral.delegate=nil;central.cancelPeripheralConnection(peripheral)
        }
        usingRetrievedPeripheral=false
        central.stopScan()
        attach(candidate)
    }
    public func centralManager(_ central:CBCentralManager,didConnect peripheral:CBPeripheral) {
        guard self.peripheral === peripheral,let code else { return }
        discoveryFallback?.cancel();discoveryFallback=nil
        if central.isScanning { central.stopScan() }
        onState("Opening Bluetooth command channel…",false)
        peripheral.discoverServices([CBUUID(nsuuid: BluetoothPairing.serviceID(code: code)), BLECharacteristics.forgetService])
    }
    public func centralManager(_ central:CBCentralManager,didFailToConnect peripheral:CBPeripheral,error:Error?) {
        if self.peripheral === peripheral { fail("Bluetooth connection failed · try reconnecting") }
    }
    public func centralManager(_ central:CBCentralManager,didDisconnectPeripheral peripheral:CBPeripheral,error:Error?) {
        if self.peripheral === peripheral { fail("Bluetooth disconnected") }
    }
    public func peripheral(_ peripheral:CBPeripheral,didDiscoverServices error:Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil, let code else { fail("Bluetooth service discovery failed"); return }
        if let active = peripheral.services?.first(where: { $0.uuid == CBUUID(nsuuid: BluetoothPairing.serviceID(code: code)) }) {
            peripheral.discoverCharacteristics([BLECharacteristics.request, BLECharacteristics.receipt], for: active)
        } else if let retired = peripheral.services?.first(where: { $0.uuid == BLECharacteristics.forgetService }) {
            peripheral.discoverCharacteristics([CBUUID(nsuuid: RevocationNotice(code: code).lookup)], for: retired)
        } else { resumeDiscovery(after: peripheral) }
    }
    private func resumeDiscovery(after candidate: CBPeripheral) {
        queriedNoticePeers.insert(candidate.identifier)
        reset()
        if manager.state == .poweredOn { beginConnection(discoveryOnly: true) }
    }
    public func peripheral(_ peripheral:CBPeripheral,didDiscoverCharacteristicsFor service:CBService,error:Error?) {
        guard self.peripheral === peripheral else { return }
        if service.uuid == BLECharacteristics.forgetService, let code {
            let lookup = CBUUID(nsuuid: RevocationNotice(code: code).lookup)
            guard error == nil, let response = service.characteristics?.first(where: { $0.uuid == lookup }) else {
                resumeDiscovery(after: peripheral)
                return
            }
            peripheral.readValue(for: response)
            return
        }
        guard error == nil,
              let input=service.characteristics?.first(where:{$0.uuid == BLECharacteristics.request && $0.properties.contains(.write)}),
              let output=service.characteristics?.first(where:{$0.uuid == BLECharacteristics.receipt && $0.properties.contains(.notify)}) else {
            fail("Bluetooth command channel is unavailable");return
        }
        self.input=input;self.output=output;peripheral.setNotifyValue(true,for:output)
    }
    public func peripheral(_ peripheral:CBPeripheral,didUpdateNotificationStateFor characteristic:CBCharacteristic,error:Error?) {
        guard self.peripheral === peripheral,characteristic.uuid == BLECharacteristics.receipt else { return }
        guard error == nil,characteristic.isNotifying,let code else { fail("Bluetooth receipts could not be enabled");return }
        do { let hello=try BluetoothPairing.hello(code:code);nonce=hello.nonce;try enqueue(hello.packet) }
        catch { fail("Bluetooth pairing could not start") }
    }
    public func peripheral(_ peripheral:CBPeripheral,didUpdateValueFor characteristic:CBCharacteristic,error:Error?) {
        if self.peripheral === peripheral, characteristic.service?.uuid == BLECharacteristics.forgetService, let code {
            let notice = RevocationNotice(code: code)
            if error == nil, characteristic.uuid == CBUUID(nsuuid: notice.lookup), characteristic.value == notice.proof {
                onPairingRevoked()
            } else { resumeDiscovery(after: peripheral) }
            return
        }
        guard self.peripheral === peripheral,characteristic.uuid == BLECharacteristics.receipt else { return }
        guard error == nil,let data=characteristic.value else { fail("Bluetooth receipt unavailable · action not retried");return }
        do {
            for packet in try decoder.append(data) {
                if session == nil {
                    guard let code,let nonce else { throw BluetoothProtocolError.invalid }
                    session=try BluetoothPairing.finish(packet:packet,code:code,phoneNonce:nonce)
                    connectionTimeout?.cancel();connectionTimeout=nil;usingRetrievedPeripheral=false
                    onAuthenticated(code, peripheral.identifier)
                    onState("Connected to Mac",true)
                } else {
                    guard let plain=try session?.open(packet) else { throw BluetoothProtocolError.invalid }
                    if let push=try? JSONDecoder().decode(HapticPreviewPush.self,from:plain) {
                        guard push.version == 1 else { throw BluetoothProtocolError.invalid }
                        onPreview(push.command)
                        continue
                    }
                    if let input=try? JSONDecoder().decode(DiscardInputAcknowledgement.self,from:plain) {
                        guard input.version == 1 else { throw BluetoothProtocolError.invalid }
                        onDiscardInput(input)
                        continue
                    }
                    if let revoked = try? JSONDecoder().decode(BluetoothPairingRevocation.self, from: plain) {
                        guard revoked.pairingRevocationVersion == 1 else { throw BluetoothProtocolError.invalid }
                        onPairingRevoked()
                        return
                    }
                    let receipt=try JSONDecoder().decode(WakeReceipt.self,from:plain)
                    guard receipt.version == 1,receipt.id == pending else { throw BluetoothProtocolError.invalid }
                    timeout?.cancel();timeout=nil;pending=nil
                    onReceipt(receipt);onState("Connected to Mac",true)
                }
            }
        } catch { fail("Bluetooth authentication or receipt failed · action not retried") }
    }
    public func send(_ request:WakeRequest=WakeRequest()) {
        guard session != nil,pending == nil else { return }
        do {
            guard let packet=try session?.seal(JSONEncoder().encode(request)) else { return }
            pending=request.id;try enqueue(packet)
            let id=generation
            timeout=Task { [weak self] in
                do { try await Task.sleep(for:.seconds(request.action == .startDictation ? 8 : 5)) } catch { return }
                guard let self,self.generation == id,self.pending == request.id else { return }
                self.fail("Bluetooth result timed out · action not retried")
            }
        } catch { fail("Bluetooth send failed · action not retried") }
    }
    private func enqueue(_ packet:Data) throws {
        let frame=try BluetoothPairing.frame(packet)
        guard outgoing.count+frame.count <= BluetoothPairing.maximumFrameBytes+4 else { throw BluetoothProtocolError.invalid }
        outgoing.append(frame);drain()
    }
    private func drain() {
        guard !writing,!outgoing.isEmpty,let peripheral,let input else { return }
        // Cap acknowledged writes to the negotiated single-write size, avoiding
        // ATT long-write offsets while retaining write-response flow control.
        let limit=min(peripheral.maximumWriteValueLength(for:.withResponse),peripheral.maximumWriteValueLength(for:.withoutResponse))
        let chunk=Data(outgoing.prefix(limit))
        guard !chunk.isEmpty else { fail("Bluetooth write limit unavailable");return }
        outgoing.removeFirst(chunk.count);writing=true
        peripheral.writeValue(chunk,for:input,type:.withResponse)
    }
    public func peripheral(_ peripheral:CBPeripheral,didWriteValueFor characteristic:CBCharacteristic,error:Error?) {
        guard self.peripheral === peripheral,characteristic.uuid == BLECharacteristics.request else { return }
        guard error == nil else { fail("Bluetooth delivery uncertain · action not retried");return }
        writing=false;drain()
    }
}
