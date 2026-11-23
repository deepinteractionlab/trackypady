// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
#if os(macOS)
import XCTest
import CryptoKit
@testable import TrackypadyBridge

final class CodexStopBindingTests: XCTestCase {
    private let handler = "begin-handler:Escape confirms then stops:end-handler"
    private let resolver = "begin-resolver:confirmation ? stop : confirm:end-resolver"
    private func signature(_ stem: String, _ source: String, start: String, end: String) -> CodexStopBinding.Signature {
        .init(assetStem: stem, start: start, end: end,
              sha256: SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined())
    }
    private var signatures: [CodexStopBinding.Signature] {
        [signature("handler.", handler, start: "begin-handler:", end: ":end-handler"),
         signature("resolver.", resolver, start: "begin-resolver:", end: ":end-resolver")]
    }

    private func archive(_ sources: [(String, String)], modify: (inout [String: [String: Any]]) -> Void = { _ in }) throws -> Data {
        var entries: [String: [String: Any]] = [:]
        var content = Data()
        for (name, source) in sources {
            let bytes = Data(source.utf8)
            entries[name] = ["size": bytes.count, "offset": String(content.count)]
            content += bytes
        }
        modify(&entries)
        var object: [String: Any] = ["files": entries]
        for name in ["async", "assets", "webview"] { object = ["files": [name: object]] }
        let json = try JSONSerialization.data(withJSONObject: object)
        let padding = (4 - json.count % 4) % 4
        var data = Data()
        for word in [4, 8 + json.count + padding, 4 + json.count + padding, json.count] {
            var value = UInt32(word).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data += json
        data += Data(repeating: 0, count: padding)
        return data + content
    }

    private func withArchive(_ data: Data, check: (URL) throws -> Void) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        try check(file)
    }

    func testBothReviewedFunctionsAreRequiredAndUnrelatedAssetEditsAreAllowed() throws {
        let sources = [("handler.newhash.js", "unrelated();" + handler + "other();"), ("resolver.newhash.js", resolver)]
        try withArchive(archive(sources)) {
            try CodexStopBinding.inspectArchive($0, signatures: signatures)
        }
        try withArchive(archive([sources[0]])) {
            XCTAssertThrowsError(try CodexStopBinding.inspectArchive($0, signatures: signatures))
        }
    }

    func testChangedKeyOrConfirmationBehaviorIsNotAssumedCompatible() throws {
        for (first, second) in [(handler.replacingOccurrences(of: "Escape", with: "F9"), resolver),
                                (handler, resolver.replacingOccurrences(of: "stop : confirm", with: "confirm : stop"))] {
            try withArchive(archive([("handler.a.js", first), ("resolver.a.js", second)])) {
                XCTAssertThrowsError(try CodexStopBinding.inspectArchive($0, signatures: signatures))
            }
        }
    }

    func testAmbiguousLinkedUnpackedAndOutOfBoundsEntriesAreRejected() throws {
        let normal = [("handler.a.js", handler), ("resolver.a.js", resolver)]
        try withArchive(archive(normal + [("handler.b.js", handler)])) {
            XCTAssertThrowsError(try CodexStopBinding.inspectArchive($0, signatures: signatures))
        }
        for override: [String: Any] in [["link": "elsewhere"], ["unpacked": true], ["offset": "18446744073709551615"], ["size": 17 * 1024 * 1024], ["size": -1]] {
            try withArchive(archive(normal) { entries in entries["handler.a.js"]?.merge(override) { _, new in new } }) {
                XCTAssertThrowsError(try CodexStopBinding.inspectArchive($0, signatures: signatures))
            }
        }
        try withArchive(Data([4, 0])) {
            XCTAssertThrowsError(try CodexStopBinding.inspectArchive($0, signatures: signatures))
        }
    }

    @MainActor
    func testRouteSelectionAndInstallationGuardsApplyToBothPaths() async throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.openai.codex", "CFBundleVersion": "test"], format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let file = bundle.appendingPathComponent("Contents/Resources/app.asar")
        for path in [CodexStopBinding.Path.full, .limited] {
            try Data("original".utf8).write(to: file, options: .atomic)
            let selected = try CodexStopBinding.select(bundleURL: bundle) { url in
                if path == .limited { throw CodexStopBinding.Failure.unsupported }
                return .init(installation: try .read(url))
            }
            XCTAssertEqual(selected.path, path)
            XCTAssertFalse(selected.isCurrent(bundleURL: bundle, launchedAt: .distantPast))
            var presses = 0
            let sent = try await ResponseStopShortcut().send(isCurrent: {
                selected.isCurrent(bundleURL: bundle, launchedAt: .distantFuture)
            }, pressEscape: { presses += 1 }, waitForConfirmation: {
                try Data("replacement".utf8).write(to: file, options: .atomic)
            })
            XCTAssertFalse(sent)
            XCTAssertEqual(presses, 1, "Never retry or switch routes after dispatch")
        }
        for failure in [CodexStopBinding.Failure.unavailable, .changed] {
            XCTAssertThrowsError(try CodexStopBinding.select(bundleURL: bundle) { _ in throw failure })
        }
        XCTAssertThrowsError(try CodexStopBinding.select(bundleURL: bundle) { _ in
            try Data("updated during inspection".utf8).write(to: file, options: .atomic)
            throw CodexStopBinding.Failure.unsupported
        })
    }

    func testInstalledRouteWhenExplicitlyRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["TRACKYPADY_TEST_CODEX_APP"] else {
            throw XCTSkip("Set TRACKYPADY_TEST_CODEX_APP for a read-only installed-app check")
        }
        let selected = try CodexStopBinding.select(bundleURL: URL(fileURLWithPath: path))
        XCTAssertTrue(selected.isCurrent(bundleURL: URL(fileURLWithPath: path), launchedAt: .distantFuture))
        print("Installed Stop path: \(selected.path.rawValue), build \(selected.installation.build)")
    }

    @MainActor
    func testReplacingCodexBetweenKeysInvalidatesVerifiedBinding() async throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info = bundle.appendingPathComponent("Contents/Info.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.openai.codex", "CFBundleVersion": "1"], format: .xml, options: 0).write(to: info)
        let file = bundle.appendingPathComponent("Contents/Resources/app.asar")
        try archive([("handler.a.js", handler), ("resolver.a.js", resolver)]).write(to: file)
        try CodexStopBinding.inspectArchive(file, signatures: signatures)
        let verification = CodexStopBinding.Verification(installation: try .read(bundle))
        XCTAssertFalse(verification.isCurrent(bundleURL: bundle, launchedAt: .distantPast))
        XCTAssertTrue(verification.isCurrent(bundleURL: bundle, launchedAt: .distantFuture))
        XCTAssertFalse(verification.isCurrent(bundleURL: bundle.appendingPathComponent("other"), launchedAt: .distantFuture))
        var presses = 0
        let sent = try await ResponseStopShortcut().send(isCurrent: {
            verification.isCurrent(bundleURL: bundle, launchedAt: .distantFuture)
        }, pressEscape: { presses += 1 }, waitForConfirmation: {
            try Data("replacement build".utf8).write(to: file, options: .atomic)
        })
        XCTAssertFalse(sent)
        XCTAssertEqual(presses, 1)
    }

    func testInstalledCodexWhenExplicitlyRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["TRACKYPADY_TEST_CODEX_APP"] else {
            throw XCTSkip("Set TRACKYPADY_TEST_CODEX_APP to smoke-test an installed Codex bundle")
        }
        let result = try CodexStopBinding.inspect(bundleURL: URL(fileURLWithPath: path))
        XCTAssertEqual(result.display, "Matches system binding")
        print("Verified Stop implementation in Codex build \(result.installation.build)")
    }
}
#endif
