// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
#if os(macOS)
import XCTest
import Carbon
@testable import TouchCore

final class MacKeyboardLayoutTests: XCTestCase {
    @MainActor func testQWERTYAndAZERTYResolveDifferentPhysicalAAndQKeys() throws {
        func source(_ id: String) throws -> TISInputSource {
            let filter=[kTISPropertyInputSourceID as String:id] as CFDictionary
            guard let list=TISCreateInputSourceList(filter,true)?.takeRetainedValue() as? [TISInputSource],let source=list.first else { throw XCTSkip("Installed layout unavailable: \(id)") }
            return source
        }
        let us=try source("com.apple.keylayout.US"),french=try source("com.apple.keylayout.French")
        XCTAssertEqual(try MacKeyboardLayout.keyCode(for:"a",source:us),0)
        XCTAssertEqual(try MacKeyboardLayout.keyCode(for:"q",source:us),12)
        XCTAssertEqual(try MacKeyboardLayout.keyCode(for:"a",source:french),12)
        XCTAssertEqual(try MacKeyboardLayout.keyCode(for:"q",source:french),0)
        XCTAssertNotEqual(try MacKeyboardLayout.keyCode(for:"s"),try MacKeyboardLayout.keyCode(for:"q"))
    }
}
#endif
