// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
import Network
import CoreImage.CIFilterBuiltins
import Vision
import TouchCore
import TouchLink

private actor Counter {
    private(set) var value=0
    func increment() { value += 1 }
}
final class TouchTests: XCTestCase,@unchecked Sendable {
    func testUnknownCommandsAndVersionsDoNotActivate() async throws {
        let unknown=Data("{\"version\":1,\"id\":\"\(UUID())\",\"action\":\"runShell\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(WakeRequest.self,from:unknown))
        let bad=try JSONDecoder().decode(WakeRequest.self,from:Data("{\"version\":2,\"id\":\"\(UUID())\",\"action\":\"wakeCodex\"}".utf8))
        let service=WakeService { _ in XCTFail("Unsupported version activated"); return WakeReceipt(id:UUID(),outcome:.failed,message:"") }
        let receipt=await service.handle(bad); XCTAssertEqual(receipt.outcome,.failed)
    }
    func testConcurrentAndRepeatedEventsExecuteOnce() async {
        let counter=Counter()
        let service=WakeService { request in
            await counter.increment(); try? await Task.sleep(for:.milliseconds(40))
            return WakeReceipt(id:request.id,outcome:.foreground,message:"Confirmed")
        }
        let request=WakeRequest()
        async let first=service.handle(request)
        async let second=service.handle(request)
        let (a,b)=await (first,second)
        XCTAssertEqual(a,b)
        let repeated=await service.handle(request); XCTAssertEqual(a,repeated)
        let count=await counter.value; XCTAssertEqual(count,1)
    }
    func testPairingQRCodeSurvivesRenderingAndRejectsCameraOrArbitraryCodes() throws {
        let code=TouchPairing.code(); let payload=TouchPairing.qrPayload(code:code)
        let filter=CIFilter.qrCodeGenerator();filter.message=Data(payload.utf8)
        let output=try XCTUnwrap(filter.outputImage).transformed(by:CGAffineTransform(scaleX:6,y:6))
        let image=try XCTUnwrap(CIContext().createCGImage(output,from:output.extent))
        let request=VNDetectBarcodesRequest();try VNImageRequestHandler(cgImage:image).perform([request])
        let decoded=try XCTUnwrap(request.results?.first?.payloadStringValue)
        XCTAssertEqual(try TouchPairing.parseQR(decoded).code,code)
        for invalid in ["https://example.com",payload.replacingOccurrences(of:"trackypady",with:"projectx-depth"),payload+"&extra=1"] {
            XCTAssertThrowsError(try TouchPairing.parseQR(invalid))
        }
    }
    func testPairingLinksKeepSecretsInFragmentAndAcceptLegacyQR() throws {
        let code = "0123456789ABCDEF01234567"
        let payload = TouchPairing.universalLinkPayload(code: code)
        let url = try XCTUnwrap(URLComponents(string: payload))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, TouchPairing.websiteHost)
        XCTAssertEqual(url.path, TouchPairing.pairingPath)
        XCTAssertNil(url.query)
        XCTAssertTrue(try XCTUnwrap(url.fragment).contains(code))
        XCTAssertEqual(try TouchPairing.parseQR(payload).code, code)
        let legacy = "trackypady://pair?v=1&name=Trackypady%2001234567&code=\(code)"
        XCTAssertEqual(try TouchPairing.parseQR(legacy).code, code)
        XCTAssertEqual(TouchPairing.qrPayload(code: code), payload)
        for invalid in [
            payload.replacingOccurrences(of: "https:", with: "http:"),
            payload.replacingOccurrences(of: TouchPairing.websiteHost, with: "attacker.example"),
            payload.replacingOccurrences(of: "/pair/", with: "/other/"),
            payload.replacingOccurrences(of: "#", with: "?"),
            payload.replacingOccurrences(of: "#", with: "?tracking=1#"),
            payload.replacingOccurrences(of: "https://", with: "https://user@"),
            payload.replacingOccurrences(of: TouchPairing.websiteHost, with: TouchPairing.websiteHost + ":443"),
            payload.replacingOccurrences(of: "v=1", with: "v=2"),
            payload + "&code=" + code,
            legacy + "#extra",
            "https://\(TouchPairing.websiteHost)/pair/#v=1&code=\(code)&code=\(code)",
            String(repeating: "a", count: 513)
        ] {
            XCTAssertThrowsError(try TouchPairing.parseQR(invalid))
        }
    }
    func testEncryptedRoundTripAndReceiptCorrelation() async throws {
        let ready=expectation(description:"Paired"),done=expectation(description:"Result")
        ready.assertForOverFulfill=false
        let request=WakeRequest();let code=TouchPairing.code()
        let client=TouchClient(onState:{ _,connected in if connected { ready.fulfill() } },onReceipt:{ receipt in
            XCTAssertEqual(receipt.id,request.id);XCTAssertEqual(receipt.outcome,.foreground);done.fulfill()
        })
        let server=TouchServer(onState:{ _ in },onRequest:{ received,reply in
            XCTAssertEqual(received,request)
            reply(WakeReceipt(id:received.id,outcome:.foreground,message:"Verified fake activator"))
        })
        server.onPort={ port in client.connect(endpoint:.hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!),code:code,loopbackOnly:true) }
        server.start(code:code,loopbackOnly:true);defer { client.stop();server.stop() }
        await fulfillment(of:[ready],timeout:10)
        client.send(request)
        await fulfillment(of:[done],timeout:10)
    }
    func testWrongPairingCodeCannotDeliverWake() async throws {
        let denied=expectation(description:"Denied");denied.assertForOverFulfill=false
        let client=TouchClient(onState:{ message,ready in
            XCTAssertFalse(ready,"Wrong pairing secret authenticated")
            if message.hasPrefix("Connection failed") || message.hasPrefix("Pairing timed out") { denied.fulfill() }
        },onReceipt:{ _ in XCTFail("Unpaired receipt") })
        let server=TouchServer(onState:{ _ in },onRequest:{ _,_ in XCTFail("Unauthenticated wake") })
        server.onPort={ port in client.connect(endpoint:.hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!),code:TouchPairing.code(),loopbackOnly:true) }
        server.start(code:TouchPairing.code(),loopbackOnly:true);defer { client.stop();server.stop() }
        await fulfillment(of:[denied],timeout:12)
    }
}
