// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
#if os(macOS)
import ApplicationServices
import XCTest
import TouchCore
@testable import TrackypadyBridge

@MainActor
final class ComposerDiscoveryTests: XCTestCase {
    func testTransientReadsRestartDiscoveryAfterStop() async throws {
        var attempts = 0
        let result = try await MainComposerLocator.discover {
            attempts += 1
            if attempts == 1 { throw MainComposerLocator.Failure(message: "Stale control", axError: .invalidUIElement) }
            if attempts == 2 { throw MainComposerLocator.Failure(message: "Renderer busy", axError: .cannotComplete) }
            return "composer"
        }
        XCTAssertEqual(result, "composer")
        XCTAssertEqual(attempts, 3)
    }

    func testExposedButEmptyWebAreaRetriesUntilComposerAppears() async throws {
        typealias Node = MainComposerSelection.Node
        var attempts = 0
        let result = try await MainComposerLocator.discover {
            attempts += 1
            if attempts == 1 {
                return try MainComposerLocator.resolveScan([Node(broadContainer: true)], complete: true)
            }
            return try MainComposerLocator.resolveScan([
                Node(children: [1, 2, 3]), Node(editor: true, richText: true),
                Node(recorderControl: true), Node(attachmentControl: true)
            ], complete: true)
        }
        XCTAssertEqual(result.field, 1)
        XCTAssertEqual(attempts, 2)
    }

    func testFocusedComposerScopeAvoidsUnrelatedTranscriptAndRequiresCapturedWindow() throws {
        // A large transcript is a sibling of the footer. Only the editor's
        // ancestry should be read, irrespective of the conversation's length.
        let classes = [1: ["ProseMirror"], 2: ["ComposerLayoutBody-uBBf1A"], 3: ["footer-A8ZvKV"]]
        let parents = [1: 2, 2: 3, 3: 0]
        var visited: [Int] = []
        let scope = MainComposerLocator.verifiedFocusedScope(field: 1, window: 0, same: ==, classes: {
            visited.append($0)
            return classes[$0] ?? []
        }, parent: { parents[$0] })
        XCTAssertEqual(scope, 3)
        XCTAssertEqual(visited, [1, 2, 3])
        let otherWindow = MainComposerLocator.verifiedFocusedScope(field: 1, window: 99, same: ==,
            classes: { classes[$0] ?? [] }, parent: { parents[$0] })
        XCTAssertNil(otherWindow)
        let sideClasses: (Int) -> [String] = { node in
            if node == 2 { return [] }
            return classes[node] ?? []
        }
        let sidePanel: Int? = MainComposerLocator.verifiedFocusedScope(field: 1, window: 0, same: { $0 == $1 },
            classes: sideClasses, parent: { parents[$0] })
        XCTAssertNil(sidePanel)
    }

    func testIncompleteOrAmbiguousComposerScanFailsWithoutRetry() async {
        typealias Node = MainComposerSelection.Node
        let scopes = [Node(children: [1, 2, 3, 4]), Node(editor: true, richText: true),
                      Node(editor: true, richText: true), Node(recorderControl: true), Node(attachmentControl: true)]
        for (nodes, complete) in [([Node(broadContainer: true)], false), (scopes, true)] {
            var attempts = 0
            do {
                _ = try await MainComposerLocator.discover {
                    attempts += 1
                    return try MainComposerLocator.resolveScan(nodes, complete: complete)
                }
                XCTFail("Expected a closed failure")
            } catch {}
            XCTAssertEqual(attempts, 1)
        }
    }

    func testPermissionFailureAndExpiredRetryReturnOriginalError() async {
        for (code, timeout) in [(AXError.apiDisabled, Duration.seconds(2)), (.invalidUIElement, .zero)] {
            var attempts = 0
            do {
                try await MainComposerLocator.discover(timeout: timeout) {
                    attempts += 1
                    throw MainComposerLocator.Failure(message: "Lookup failed", axError: code)
                }
                XCTFail("Expected lookup failure")
            } catch {
                XCTAssertEqual((error as? MainComposerLocator.Failure)?.axError, code)
            }
            XCTAssertEqual(attempts, 1)
        }
    }
}
#endif
