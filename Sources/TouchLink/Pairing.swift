// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
// Adapted from Project X camera prototype: QR/Bonjour and TLS-PSK pairing.
@preconcurrency import Network
import Security
import CryptoKit
import Foundation

public enum TouchPairing {
    public static let service="_trackypady._tcp"
    public static let websiteHost = "deepinteractionlab.github.io"
    public static let pairingPath = "/trackypady/pair/"
    public static func code() -> String {
        var random=SystemRandomNumberGenerator()
        return (0..<12).map { _ in String(format:"%02X",UInt8.random(in:0...255,using:&random)) }.joined()
    }
    public static func normalized(_ code: String) -> String {
        code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    }
    public static func serviceName(code: String) -> String {
        "Trackypady " + normalized(code).prefix(8)
    }
    // Bonjour names are public. Advertise an opaque identifier derived from the pairing.
    static func localServiceName(code: String) -> String {
        let digest = SHA256.hash(data: Data(("Trackypady Bonjour " + normalized(code)).utf8))
        return "Trackypady " + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    public static func qrPayload(code: String) -> String {
        return universalLinkPayload(code: code)
    }

    /// Keep the existing local pairing secret in the fragment, outside HTTP requests.
    public static func universalLinkPayload(code: String) -> String {
        var payload = URLComponents()
        payload.queryItems = pairingItems(code: code)
        var url=URLComponents()
        url.scheme = "https"
        url.host = websiteHost
        url.path = pairingPath
        url.percentEncodedFragment = payload.percentEncodedQuery
        return url.string ?? ""
    }

    private static func pairingItems(code: String) -> [URLQueryItem] {
        [URLQueryItem(name: "v", value: "1"),
         URLQueryItem(name: "name", value: serviceName(code: code)),
         URLQueryItem(name: "code", value: normalized(code))]
    }
    public static func parseQR(_ text: String) throws -> (name: String, code: String) {
        func invalid() -> NSError {
            NSError(domain:"Trackypady",code:2,userInfo:[NSLocalizedDescriptionKey:"Scan the pairing QR code displayed in Trackypady Bridge."])
        }
        guard text.utf8.count <= 512, let url=URLComponents(string:text),
              url.user == nil,url.password == nil,url.port == nil else { throw invalid() }
        let items: [URLQueryItem]
        if url.scheme == "https", url.host == websiteHost, url.path == pairingPath,
           url.query == nil, let fragment = url.percentEncodedFragment {
            var payload = URLComponents()
            payload.percentEncodedQuery = fragment
            guard let queryItems = payload.queryItems else { throw invalid() }
            items = queryItems
        } else if url.scheme == "trackypady", url.host == "pair",
                  url.path.isEmpty, url.fragment == nil, let queryItems = url.queryItems {
            // Retain QR codes from older Mac builds and the website's Open App button.
            items = queryItems
        } else { throw invalid() }
        guard
              items.count == 3,Set(items.map(\.name)) == Set(["v","name","code"]),
              items.first(where: { $0.name == "v" })?.value == "1",
              let name=items.first(where: { $0.name == "name" })?.value,
              let raw=items.first(where: { $0.name == "code" })?.value else { throw invalid() }
        let code=normalized(raw)
        guard code.count == 24,code.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }),
              name == serviceName(code:code) else { throw invalid() }
        return (name,code)
    }
    public static func parameters(code: String,loopbackOnly: Bool=false,allowEthernet: Bool=false) throws -> NWParameters {
        let code=normalized(code)
        guard code.count == 24, code.allSatisfy(\.isHexDigit) else {
            throw NSError(domain:"Trackypady",code:1,userInfo:[NSLocalizedDescriptionKey:"Enter the 24-character pairing code shown on the Mac."])
        }
        let tls=NWProtocolTLS.Options()
        let key=Array(SHA256.hash(data:Data(code.utf8)))
        let identity=Array("Trackypady-v1".utf8)
        key.withUnsafeBytes { k in identity.withUnsafeBytes { i in
            sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                DispatchData(bytes:k) as __DispatchData,DispatchData(bytes:i) as __DispatchData)
        } }
        // Network.framework's PSK path supports TLS 1.2 (not TLS 1.3).
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions,.TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions,.TLSv12)
        if let suite=tls_ciphersuite_t(rawValue:0x00A8) {
            sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,suite)
        }
        let tcp=NWProtocolTCP.Options(); tcp.noDelay=true
        let parameters=NWParameters(tls:tls,tcp:tcp)
        // Phone traffic requires Wi-Fi. The Mac listener accepts Wi-Fi and
        // wired Ethernet on the same LAN. Loopback is explicit for tests.
        if loopbackOnly { parameters.requiredInterfaceType = .loopback }
        else if allowEthernet { parameters.prohibitedInterfaceTypes = [.cellular,.loopback,.other] }
        else { parameters.requiredInterfaceType = .wifi }
        parameters.includePeerToPeer=false
        return parameters
    }
}

public struct NearbyMac: Identifiable, @unchecked Sendable {
    public var id: String { endpoint.debugDescription }
    public let name: String
    public let endpoint: NWEndpoint
}

public final class TouchBrowser: @unchecked Sendable {
    private let queue=DispatchQueue(label:"com.deepinteractionlab.trackypady.browser")
    private var browser: NWBrowser?
    private let onResults: @Sendable ([NearbyMac])->Void
    public init(onResults: @escaping @Sendable ([NearbyMac])->Void) { self.onResults=onResults }
    public func start() {
        queue.async { [self] in
            browser?.cancel()
            let parameters=NWParameters.tcp
            parameters.requiredInterfaceType = .wifi
            parameters.includePeerToPeer=false
            let browser=NWBrowser(for:.bonjour(type:TouchPairing.service,domain:nil),using:parameters)
            browser.browseResultsChangedHandler = { [weak self] results,_ in
                self?.onResults(results.compactMap { result in
                    guard case .service(let name,_,_,_) = result.endpoint else { return nil }
                    return NearbyMac(name:name,endpoint:result.endpoint)
                }.sorted { $0.name < $1.name })
            }
            self.browser=browser; browser.start(queue:queue)
        }
    }
    public func stop() { queue.async { [self] in browser?.cancel(); browser=nil } }
}
