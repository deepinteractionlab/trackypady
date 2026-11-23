// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import XCTest
@testable import CharacterKit

final class RecordingErrorAnimationTests: XCTestCase {
    func testFlatlineRemovesPeaksAndHandDrawnWobbleWithoutNarrowingTheStroke() {
        let rect = CGRect(x: 0, y: 0, width: 150, height: 80)
        var wave = HandDrawnWaveform(peakContrast: 0.5, spacingContrast: 0.5, irregularity: 0.8,
                                     seed: 2468, height: 65, cycles: 3, wiggle: 0.08, spacing: 80,
                                     width: 3, variation: 0, motionAmount: 0.8)
        XCTAssertGreaterThan(wave.path(in: rect).boundingRect.height, 10)
        wave.waveScale = RecordingErrorMotion.waveScale(elapsed: 0.5, reduceMotion: false)
        for phase in [0.0, 0.75] {
            wave.motionTime = phase
            wave.domainOffset = phase
            let bounds = wave.path(in: rect).boundingRect
            XCTAssertEqual(bounds.midY, rect.midY, accuracy: 0.001)
            XCTAssertEqual(bounds.height, 3, accuracy: 0.001)
            XCTAssertEqual(bounds.width, 153, accuracy: 0.001)
        }
    }

    func testErrorSettlesIn140MillisecondsAndReduceMotionShowsFlatlineImmediately() {
        XCTAssertEqual(RecordingErrorMotion.waveScale(elapsed: 0, reduceMotion: false), 1)
        XCTAssertEqual(RecordingErrorMotion.waveScale(elapsed: 0.07, reduceMotion: false), 0.5, accuracy: 0.001)
        XCTAssertEqual(RecordingErrorMotion.waveScale(elapsed: 0.14, reduceMotion: false), 0)
        XCTAssertEqual(RecordingErrorMotion.waveScale(elapsed: 0, reduceMotion: true), 0)
    }
}
