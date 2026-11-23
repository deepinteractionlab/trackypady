// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import dnssd
import Foundation
@preconcurrency import Network

/// The lookup may travel on the network. Only disclose its independent proof after Forget.
public struct RevocationNotice: Codable, Equatable, Sendable {
    let lookup: UUID
    let proof: Data

    init(code: String) {
        let key = SymmetricKey(data: Data(TouchPairing.normalized(code).utf8))
        func tag(_ label: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(("Trackypady forget v1 " + label).utf8), using: key))
        }
        let b = Array(tag("lookup").prefix(16))
        lookup = UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
        proof = tag("proof")
    }
}

/// Publish DNS-SD aliases on the existing listener's port. The phone browses TXT
/// responses without presenting the old credential or opening a command session.
@MainActor
final class RevocationAdvertisements {
    private var services: [NetService] = []

    func publish(_ notices: [RevocationNotice], port: UInt16) {
        stop()
        for notice in notices {
            let service = NetService(domain: "local.", type: TouchPairing.service + ".",
                                     name: notice.lookup.uuidString, port: Int32(port))
            service.setTXTRecord(NetService.data(fromTXTRecord: ["pairingRevoked": Data(notice.proof.base64EncodedString().utf8)]))
            service.publish()
            services.append(service)
        }
    }

    func stop() {
        services.forEach { $0.stop() }
        services.removeAll()
    }

    static func browse(for notice: RevocationNotice, onPolicyChange: @escaping @MainActor (Bool) -> Void = { _ in }, onRevoked: @escaping @MainActor () -> Void) -> NWBrowser {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: TouchPairing.service, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { state in
            MainActor.assumeIsolated {
                switch state {
                case .waiting(.dns(let code)), .failed(.dns(let code)):
                    onPolicyChange(Int(code) == kDNSServiceErr_PolicyDenied)
                case .ready: onPolicyChange(false)
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { results, _ in
            MainActor.assumeIsolated {
                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint, name == notice.lookup.uuidString,
                          case .bonjour(let txt) = result.metadata,
                          txt.dictionary["pairingRevoked"] == notice.proof.base64EncodedString() else { continue }
                    onRevoked()
                    break
                }
            }
        }
        browser.start(queue: .main)
        return browser
    }
}
