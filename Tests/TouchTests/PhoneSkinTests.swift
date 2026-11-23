// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import CharacterKit

final class PhoneSkinTests: XCTestCase {
    @MainActor
    func testBundledSkinMapsEventsAndKeepsQueueAndDraftHandoffs() {
        let skin = StudioEyesSkin()
        XCTAssertEqual(skin.animation(recording: false), .idle)
        XCTAssertEqual(skin.animation(recording: true), .dictation)
        skin.handle(.steer)
        skin.handle(.queueHoldEnded)
        XCTAssertEqual(skin.animation(recording: false), .steer)
        skin.handle(.queueHoldBegan)
        let launch = skin.send?.start
        skin.handle(.queueCommitted)
        skin.handle(.queueHoldEnded)
        XCTAssertEqual(skin.send?.start, launch)
        XCTAssertEqual(skin.animation(recording: false), .queue)
        skin.handle(.stopped(.left))
        XCTAssertEqual(skin.animation(recording: false), .stopLeft)
        skin.handle(.stopped(.right))
        XCTAssertEqual(skin.animation(recording: false), .stopRight)
        skin.handle(.draftInput(.selecting))
        XCTAssertEqual(skin.animation(recording: false), .select)
        skin.handle(.recordingError)
        XCTAssertEqual(skin.animation(recording: false), .recordingError)
        skin.handle(.recordingAcknowledged)
        XCTAssertEqual(skin.animation(recording: false), .select)
        skin.handle(.draftInput(.discarding))
        skin.handle(.selectionCleared)
        XCTAssertEqual(skin.animation(recording: false), .discard)
        skin.handle(.reset)
        XCTAssertEqual(skin.animation(recording: false), .idle)
    }

    @MainActor
    func testAlternateSheetMovesOneAnimationAndRejectsUnknownPositions() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.copyItem(at: StudioEyesSkin.bundledSheetURL.deletingLastPathComponent(), to: directory)
        defer { try? fm.removeItem(at: directory) }
        let url = directory.appendingPathComponent("skin.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var positions = try XCTUnwrap(json["positions"] as? [String: [String: Double]])
        var middle = try XCTUnwrap(positions["upperThird"])
        middle["y"] = 0.5
        positions["middle"] = middle
        json["positions"] = positions
        var entries = try XCTUnwrap(json["animations"] as? [String: [String: String]])
        entries["discard"] = ["position": "middle"]
        entries["idle"] = [:]
        json["animations"] = entries
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let sheet = try StudioEyesSkin(sheetURL: url).sheet
        let screen = CGSize(width: 390, height: 780), drawing = CGSize(width: 460, height: 236)
        let idle = sheet.position(for: .idle).layout(in: screen, drawing: drawing, headroom: 56)
        let discard = sheet.position(for: .discard).layout(in: screen, drawing: drawing, headroom: 56)
        XCTAssertEqual(idle.center.x, 195)
        XCTAssertEqual(discard.center.y - idle.center.y, 260, accuracy: 0.01)
        XCTAssertEqual(idle.scale, discard.scale)
        entries["discard"] = ["position": "missing"]
        json["animations"] = entries
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertThrowsError(try StudioEyesSkin(sheetURL: url))
    }
}
