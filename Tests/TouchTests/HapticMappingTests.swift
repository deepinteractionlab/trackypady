// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
import TouchCore

final class HapticMappingTests: XCTestCase {
    func testCellCyclePersistsReverseAndLegacyMappingsStayForward() throws {
        var mapping=HapticMapping(assignments:[:])
        mapping.cycle(.queueComplete,for:.draftDiscarded)
        XCTAssertEqual(mapping[.draftDiscarded],.queueComplete);XCTAssertFalse(mapping.isReversed(.draftDiscarded))
        let forwardRevision=mapping.revision
        mapping.cycle(.queueComplete,for:.draftDiscarded)
        XCTAssertTrue(mapping.isReversed(.draftDiscarded));XCTAssertNotEqual(mapping.revision,forwardRevision)
        let restored=try JSONDecoder().decode(HapticMapping.self,from:JSONEncoder().encode(mapping))
        XCTAssertEqual(restored,mapping)
        var legacy=try JSONSerialization.jsonObject(with:JSONEncoder().encode(mapping)) as! [String:Any]
        legacy.removeValue(forKey:"reversedMoments")
        XCTAssertFalse(try JSONDecoder().decode(HapticMapping.self,from:JSONSerialization.data(withJSONObject:legacy)).isReversed(.draftDiscarded))
        mapping.cycle(.queueComplete,for:.draftDiscarded)
        XCTAssertNil(mapping[.draftDiscarded]);XCTAssertFalse(mapping.isReversed(.draftDiscarded))
        mapping.set(.wake,reversed:true,for:.wakeInput);mapping.restoreDefaults()
        XCTAssertTrue(mapping.reversedMoments.isEmpty)
    }
    func testEditsHaveFreshRevisionAndPersistOffAndSharedPatterns() throws {
        var mapping=HapticMapping.defaults
        let original=mapping.revision
        mapping.set(.wake,for:.wakeInput);XCTAssertEqual(mapping.revision,original)
        mapping.set(nil,for:.wakeInput);XCTAssertNotEqual(mapping.revision,original)
        mapping.set(.recordingStart,for:.draftDiscarded)
        mapping.set(.recordingStart,for:.transcriptDone)
        let restored=try JSONDecoder().decode(HapticMapping.self,from:JSONEncoder().encode(mapping))
        XCTAssertEqual(restored,mapping);XCTAssertNil(restored[.wakeInput])
        XCTAssertEqual(restored[.draftDiscarded],restored[.transcriptDone])
        mapping.restoreDefaults()
        XCTAssertEqual(mapping.assignments,HapticMapping.defaults.assignments)
        XCTAssertNotEqual(mapping.revision,HapticMapping.defaults.revision)
    }
    func testMappingFitsStatusPayloadAndLegacyMessagesNeedNoMapping() throws {
        let request=WakeRequest(action:.getStatus,hapticMappingRevision:HapticMapping.defaults.revision)
        let receipt=WakeReceipt(id:request.id,outcome:.status,message:"",status:BridgeStatus(codexForeground:true,dictation:.idle),hapticPreview:HapticPreviewCommand(sessionID:UUID(),cue:.recording),hapticMapping:.defaults)
        let data=try JSONEncoder().encode(receipt)
        XCTAssertLessThan(data.count,4096)
        XCTAssertEqual(try JSONDecoder().decode(WakeReceipt.self,from:data).hapticMapping,.defaults)
        let legacy=Data("{\"id\":\"\(UUID())\",\"version\":1,\"action\":\"getStatus\"}".utf8)
        XCTAssertNil(try JSONDecoder().decode(WakeRequest.self,from:legacy).hapticMappingRevision)
    }
}
