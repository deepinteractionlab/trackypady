// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import CharacterKit

final class DraftCharacterTests: XCTestCase {
    func testTwoQuickSwipesFinishSelectBeforeRetracting() throws {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let select = DraftPreview(.select, at: start)
        let discard = DraftPreview(.discard, at: start.addingTimeInterval(0.01), following: select)
        let snap = try XCTUnwrap(discard.sample(0.04))
        XCTAssertEqual(snap.length, 1)
        XCTAssertEqual(snap.bend, try XCTUnwrap(select.sample(0.05)).bend, accuracy: 0.00001)
        let retract = try XCTUnwrap(discard.sample(0.09))
        XCTAssertLessThan(retract.length, 1)
        XCTAssertGreaterThan(retract.length, 0)
        XCTAssertEqual(retract.bend, 0.25, accuracy: 0.00001)
        XCTAssertNotNil(discard.sample(0.17)?.burst)
        XCTAssertNil(discard.sample(0.40))
    }

    func testManualSelectionDiscardsImmediatelyAndReturnsToIdle() throws {
        let discard = DraftPreview(.discard)
        XCTAssertLessThan(try XCTUnwrap(discard.sample(0.08)).length, 0.25)
        XCTAssertEqual(discard.sample(0.095)?.burst, 0)
        let blank = try XCTUnwrap(discard.sample(0.30))
        XCTAssertEqual(blank.length, 0)
        XCTAssertNil(blank.burst)
        XCTAssertNil(discard.sample(0.34))
    }
}
