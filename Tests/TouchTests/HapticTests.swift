// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
import CoreHaptics
@testable import TouchCore

final class AHAPTests: XCTestCase {
    private var assets: URL {
        URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/Haptics")
    }
    func testAllOriginalPatternsNormalizeAndLoadInApplesParser() throws {
        let expected:[HapticCue:Double]=[.wake:0.07,.recordingStart:0.07,.recording:3,.recordingError:0.44,.steering:0.2,.queuePending:0.62,.queueComplete:0.7,.draftSelected:0.56,.draftDiscarded:0.16,.stopComplete:0.24]
        for cue in HapticCue.allCases {
            let original=try Data(contentsOf:assets.appendingPathComponent(cue.rawValue+".ahap"))
            let normalized=try AHAPNormalizer.normalize(original)
            let source=try JSONSerialization.jsonObject(with:original) as! [String:Any]
            let result=try JSONSerialization.jsonObject(with:normalized) as! [String:Any]
            let before=source["Pattern"] as! [[String:Any]],after=result["Pattern"] as! [[String:Any]]
            XCTAssertEqual(before.count,after.count)
            var starts:[Double]=[]
            for (lhs,rhs) in zip(before,after) {
                for key in ["Event","Parameter","ParameterCurve"] {
                    if var a=lhs[key] as? [String:Any],var b=rhs[key] as? [String:Any] {
                        starts.append((b["Time"] as! NSNumber).doubleValue)
                        a.removeValue(forKey:"Time");b.removeValue(forKey:"Time")
                        XCTAssertEqual(NSDictionary(dictionary:a),NSDictionary(dictionary:b),"Internal shape changed: \(cue)")
                    }
                }
            }
            XCTAssertEqual(starts.min(),0)
            let pattern=try CHHapticPattern(dictionary:Dictionary(uniqueKeysWithValues:result.map { (CHHapticPattern.Key(rawValue:$0.key),$0.value) }))
            XCTAssertEqual(pattern.duration,expected[cue]!,accuracy:0.00001,"\(cue)")
            XCTAssertEqual(try AHAPNormalizer.normalize(normalized),normalized,"Normalization must be idempotent")
        }
    }
    func testReversedAssetsLoadAndPreserveDurations() throws {
        for cue in HapticCue.allCases {
            let url=assets.appendingPathComponent(cue.rawValue+".ahap")
            let original=try Data(contentsOf:url)
            func pattern(_ data: Data) throws -> CHHapticPattern {
                let json=try JSONSerialization.jsonObject(with:data) as! [String:Any]
                return try CHHapticPattern(dictionary:Dictionary(uniqueKeysWithValues:json.map { (CHHapticPattern.Key(rawValue:$0.key),$0.value) }))
            }
            let reversed=try AHAPReverser.reverse(original)
            XCTAssertEqual(try pattern(reversed).duration,try pattern(AHAPNormalizer.normalize(original)).duration,accuracy:0.00001,"\(cue)")
            XCTAssertEqual(try Data(contentsOf:url),original)
        }
    }
    func testReversalMirrorsPulseOrderAndContinuousControlPoints() throws {
        let input=Data(#"{"Pattern":[{"Event":{"Time":0,"EventType":"HapticContinuous","EventDuration":0.1,"EventParameters":[{"ParameterID":"HapticIntensity","ParameterValue":0.2}]}},{"Event":{"Time":0.3,"EventType":"HapticContinuous","EventDuration":0.2,"EventParameters":[{"ParameterID":"HapticIntensity","ParameterValue":0.9}]}},{"ParameterCurve":{"Time":0,"ParameterID":"HapticIntensityControl","ParameterCurveControlPoints":[{"Time":0,"ParameterValue":0.1},{"Time":0.2,"ParameterValue":0.8},{"Time":0.5,"ParameterValue":0.4}]}}]}"#.utf8)
        let json=try JSONSerialization.jsonObject(with:AHAPReverser.reverse(input)) as! [String:Any]
        let entries=json["Pattern"] as! [[String:Any]]
        let events=entries.compactMap { $0["Event"] as? [String:Any] }
        XCTAssertEqual(events[0]["Time"] as! Double,0,accuracy:0.000001)
        XCTAssertEqual(events[1]["Time"] as! Double,0.4,accuracy:0.000001)
        XCTAssertEqual((events[0]["EventParameters"] as! [[String:Any]])[0]["ParameterValue"] as! Double,0.9)
        let curve=entries.compactMap { $0["ParameterCurve"] as? [String:Any] }[0]
        let points=curve["ParameterCurveControlPoints"] as! [[String:Any]]
        XCTAssertEqual(points.map { $0["ParameterValue"] as! Double },[0.4,0.8,0.1])
        XCTAssertEqual(points[1]["Time"] as! Double,0.3,accuracy:0.000001)
    }
    func testReverseRejectsUnsupportedAudio() {
        XCTAssertThrowsError(try AHAPReverser.reverse(Data(#"{"Pattern":[{"Event":{"Time":0,"EventType":"AudioContinuous","EventDuration":1}}]}"#.utf8)))
    }
    func testInvalidOrAmbiguousTimesAreRejected() throws {
        for json in ["{}","{\"Pattern\":[]}","{\"Pattern\":[{\"Event\":{\"Time\":-1}}]}","{\"Pattern\":[{\"Event\":{\"Time\":true}}]}","{\"Pattern\":[{\"Event\":{}}]}"] {
            XCTAssertThrowsError(try AHAPNormalizer.normalize(Data(json.utf8)))
        }
    }
}

@MainActor
private final class FakeHapticDriver: HapticDriver {
    var onInterruption: (@MainActor ()->Void)?
    var calls:[(cue:HapticCue,loop:Bool,reversed:Bool,delay:TimeInterval)]=[]
    var callbacks:[@MainActor (Bool)->Void]=[]
    var stops=0
    var fail=false
    enum Failure: Error { case playback }
    func play(_ cue: HapticCue,loop: Bool,reversed: Bool,delay: TimeInterval,completion: @escaping @MainActor (Bool)->Void) throws {
        if fail { throw Failure.playback }
        calls.append((cue,loop,reversed,delay));callbacks.append(completion)
    }
    func stop() { stops+=1 }
}

final class HapticPlaybackTests: XCTestCase {
    @MainActor func testMutingStopsRecordingAndBlocksQueuedAndDirectPlaybackUntilUnmuted() {
        let driver = FakeHapticDriver(), haptics = TouchHaptics(driver: driver)
        haptics.recordingStarted(combined: false)
        haptics.isMuted = true
        XCTAssertNil(haptics.currentCue)
        driver.callbacks[0](true)
        haptics.queueHoldChanged(true)
        haptics.play(.stopComplete)
        haptics.isMuted = false
        XCTAssertEqual(driver.calls.map(\.cue), [.recordingStart])
        haptics.queueHoldChanged(true)
        XCTAssertEqual(driver.calls.last?.cue, .queuePending)
    }

    @MainActor func testReversedMomentMatchesPreviewAndLiveOrientationUpdate() {
        var mapping=HapticMapping.defaults
        mapping.set(.queueComplete,reversed:true,for:.recordingStart)
        let driver=FakeHapticDriver(),haptics=TouchHaptics(driver:driver,mapping:mapping)
        haptics.recordingStarted(combined:false)
        XCTAssertTrue(driver.calls.last!.reversed)
        driver.callbacks[0](true)
        XCTAssertFalse(driver.calls.last!.reversed)
        mapping.set(.recording,reversed:true,for:.recordingOngoing);haptics.updateMapping(mapping)
        XCTAssertTrue(driver.calls.last!.reversed);XCTAssertTrue(driver.calls.last!.loop)
        haptics.play(.queueComplete,reversed:mapping.isReversed(.recordingStart))
        XCTAssertTrue(driver.calls.last!.reversed)
        haptics.play(.queueComplete)
        XCTAssertFalse(driver.calls.last!.reversed)
        haptics.stop();XCTAssertFalse(haptics.currentReversed)
    }
    @MainActor func testRemappedRecordingSequenceStopsByMomentRatherThanPatternName() {
        var mapping=HapticMapping.defaults
        mapping.set(.wake,for:.recordingStart);mapping.set(.draftDiscarded,for:.recordingOngoing)
        let driver=FakeHapticDriver(),haptics=TouchHaptics(driver:driver,mapping:mapping)
        haptics.recordingStarted(combined:false)
        XCTAssertEqual(driver.calls.last?.cue,.wake)
        driver.callbacks[0](true)
        XCTAssertEqual(driver.calls.last?.cue,.draftDiscarded)
        XCTAssertTrue(driver.calls.last!.loop)
        haptics.recordingReleased()
        XCTAssertNil(haptics.currentCue)
        XCTAssertNil(haptics.currentMoment)
    }
    @MainActor func testMappingUpdatesReplaceActiveLoopAndCannotReviveOldStartCallback() {
        let driver=FakeHapticDriver(),haptics=TouchHaptics(driver:driver)
        haptics.recordingStarted(combined:false)
        var mapping=HapticMapping.defaults;mapping.set(.wake,for:.recordingStart)
        haptics.updateMapping(mapping)
        driver.callbacks[0](true)
        XCTAssertEqual(driver.calls.count,2)
        XCTAssertEqual(driver.calls.last?.cue,.wake)
        driver.callbacks[1](true)
        mapping.set(.draftSelected,for:.recordingOngoing);haptics.updateMapping(mapping)
        XCTAssertEqual(driver.calls.last?.cue,.draftSelected)
        XCTAssertTrue(driver.calls.last!.loop)
        haptics.recordingReleased();XCTAssertNil(haptics.currentCue)
    }
    @MainActor func testOffRecordingStartSkipsToOngoingAndSilentLoopCanBeRemappedWhileHeld() {
        var mapping=HapticMapping.defaults
        mapping.set(nil,for:.recordingStart);mapping.set(nil,for:.recordingOngoing)
        let driver=FakeHapticDriver(),haptics=TouchHaptics(driver:driver,mapping:mapping)
        haptics.recordingStarted(combined:false)
        XCTAssertTrue(driver.calls.isEmpty)
        XCTAssertEqual(haptics.currentMoment,.recordingOngoing)
        mapping.set(.recording,for:.recordingOngoing);haptics.updateMapping(mapping)
        XCTAssertEqual(driver.calls.last?.cue,.recording)
        haptics.recordingReleased()
        mapping.set(.wake,for:.recordingOngoing);haptics.updateMapping(mapping)
        XCTAssertNil(haptics.currentCue)
    }
    @MainActor func testQueueReleasePreservesRemappedCompletionAndPreviewIgnoresMappings() {
        var mapping=HapticMapping.defaults
        mapping.set(.recording,for:.queueComplete)
        let driver=FakeHapticDriver(),haptics=TouchHaptics(driver:driver,mapping:mapping)
        haptics.queueHoldChanged(true);haptics.playMoment(.queueComplete);haptics.queueHoldChanged(false)
        XCTAssertEqual(haptics.currentCue,.recording)
        XCTAssertEqual(haptics.currentMoment,.queueComplete)
        haptics.play(.recordingStart)
        mapping.set(nil,for:.recordingStart);haptics.updateMapping(mapping)
        XCTAssertEqual(haptics.currentCue,.recordingStart)
        driver.callbacks.last!(true)
        XCTAssertNil(haptics.currentCue)
    }
    @MainActor func testRecordingStartSequencesIntoLoopAndReleaseStopsIt() {
        let driver=FakeHapticDriver(),haptics=TouchHaptics(driver:driver)
        haptics.recordingStarted(combined:false)
        XCTAssertEqual(driver.calls.last?.cue,.recordingStart)
        XCTAssertEqual(driver.calls.last?.loop,false)
        driver.callbacks[0](true)
        XCTAssertEqual(driver.calls.last?.cue,.recording)
        XCTAssertEqual(driver.calls.last?.loop,true)
        haptics.recordingReleased()
        XCTAssertNil(haptics.currentCue)
    }
    @MainActor func testStopAndDictatePlaysStartOnceThenSchedulesOngoingWithAGap() {
        let driver = FakeHapticDriver(), haptics = TouchHaptics(driver: driver)
        haptics.play(.stopComplete)
        haptics.recordingStarted(combined: false, afterStop: true)
        driver.callbacks[0](true) // Late Stop completion cannot replace the start pulse.
        XCTAssertEqual(driver.calls.map(\.cue), [.stopComplete, .recordingStart])
        XCTAssertEqual(driver.calls.last?.delay, 0)
        XCTAssertEqual(driver.calls.last?.loop, false)
        driver.callbacks[1](true)
        XCTAssertEqual(driver.calls.map(\.cue), [.stopComplete, .recordingStart, .recording])
        XCTAssertEqual(driver.calls.last?.delay, 0.15)
        XCTAssertEqual(driver.calls.last?.loop, true)
        haptics.recordingReleased()
        XCTAssertNil(haptics.currentCue)
    }

    @MainActor func testReleaseBeforeStartCompletesCannotResumeRecording() {
        let driver=FakeHapticDriver(),haptics=TouchHaptics(driver:driver)
        haptics.recordingStarted(combined:false)
        haptics.recordingReleased()
        driver.callbacks[0](true)
        XCTAssertEqual(driver.calls.count,1)
        XCTAssertNil(haptics.currentCue)
    }
    @MainActor func testCombinedEntryHasNoAdditionalStartAndOldCallbacksCannotReplaceNewCue() {
        let driver=FakeHapticDriver(),haptics=TouchHaptics(driver:driver)
        haptics.recordingStarted(combined:true)
        XCTAssertEqual(driver.calls.last?.cue,.recording)
        haptics.play(.draftSelected)
        driver.callbacks[0](true)
        XCTAssertEqual(haptics.currentCue,.draftSelected)
        XCTAssertFalse(driver.calls.last!.loop)
    }
    @MainActor func testQueueTransitionStartsOnlyOneLoopAndReleaseDoesNotCancelCompletion() {
        let driver=FakeHapticDriver(),haptics=TouchHaptics(driver:driver)
        haptics.queueHoldChanged(true);haptics.queueHoldChanged(true)
        XCTAssertEqual(driver.calls.count,1)
        haptics.queueHoldChanged(false)
        XCTAssertNil(haptics.currentCue)
        haptics.play(.queueComplete)
        haptics.queueHoldChanged(false)
        XCTAssertEqual(haptics.currentCue,.queueComplete)
    }
    @MainActor func testInterruptionInvalidatesSequenceAndFailureDoesNotStartNextCue() {
        let driver=FakeHapticDriver(),haptics=TouchHaptics(driver:driver)
        haptics.recordingStarted(combined:false)
        driver.onInterruption?()
        driver.callbacks[0](true)
        XCTAssertNil(haptics.currentCue)
        XCTAssertEqual(driver.calls.count,1)
        haptics.recordingStarted(combined:false)
        driver.callbacks[1](false)
        XCTAssertNil(haptics.currentCue)
        XCTAssertEqual(driver.calls.count,2)
        driver.fail=true
        var failures=0;haptics.onFailure={ _ in failures+=1 }
        haptics.play(.wake)
        XCTAssertEqual(failures,1)
        XCTAssertNil(haptics.currentCue)
    }
}
