// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
import TouchCore

final class BoundedSearchTests: XCTestCase {
    func testTruncatedSearchCannotProveOneControlIsUnique() throws {
        let graph=[0:[1,2],1:[],2:[3],3:[]]
        let scan=boundedSearch(root:0,limit:3) { SearchSnapshot(matches:$0==1 || $0==3,children:graph[$0] ?? []) }
        XCTAssertEqual(scan.matches,[1]);XCTAssertFalse(scan.complete)
        let full=boundedSearch(root:0,limit:4) { SearchSnapshot(matches:$0==1 || $0==3,children:graph[$0] ?? []) }
        XCTAssertTrue(full.complete);XCTAssertEqual(full.matches,[1,3])
    }
    func testSharedNodesAndCyclesDoNotDuplicateControlsOrConsumeBudget() {
        let graph=[0:[1,2],1:[2,0],2:[1]]
        let scan=boundedSearch(root:0,limit:3) { SearchSnapshot(matches:$0==2,children:graph[$0] ?? []) }
        XCTAssertTrue(scan.complete);XCTAssertEqual(scan.matches,[2]);XCTAssertEqual(scan.visited,3)
    }
    func testFailedSubtreeReadCannotBeReportedAsACompleteSearch() {
        enum ReadError: Error { case unavailable }
        XCTAssertThrowsError(try boundedSearch(root:0,limit:10) { node in
            if node==1 { throw ReadError.unavailable }
            return SearchSnapshot(matches:false,children:[1])
        })
    }
}
