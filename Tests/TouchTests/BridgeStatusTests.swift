// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import XCTest
import TouchCore

final class BridgeStatusTests: XCTestCase {
    func testMacActivityIsIdleRegardlessOfCodexFocus() {
        for foreground in [true, false] {
            let status = BridgeStatus(codexForeground: foreground, dictation: .idle)
            XCTAssertEqual(TouchPresentation.headline(connected: true, status: status, surface: .macActivity), "Idle")
            XCTAssertEqual(TouchPresentation.instruction(connected: true, status: status, surface: .macActivity), "")
            XCTAssertEqual(TouchPresentation.headline(connected: true, phase: .starting, status: status, surface: .macActivity), "Starting dictation…")
        }
    }

    func testStoppedDictationDoesNotLockComposerOrFreshHoldShortcut() {
        var progress=TranscriptionProgress();progress.begin();progress.observe(.failed)
        XCTAssertEqual(progress.state,.failed)
        XCTAssertTrue(progress.state.permitsComposerCommands)
        for state: BridgeStatus.Dictation in [.idle,.ready,.transcribing] { XCTAssertTrue(state.permitsComposerCommands) }
        for state: BridgeStatus.Dictation in [.recording,.unknown] { XCTAssertFalse(state.permitsComposerCommands) }
        XCTAssertTrue(DictationReadiness.canStart(allLabels:["Retry dictation"],enabledLabels:["Retry dictation"]))
        XCTAssertFalse(DictationReadiness.canStart(allLabels:["Retry dictation"],enabledLabels:[]))
        for label in DictationReadiness.busyLabels {
            XCTAssertFalse(DictationReadiness.canStart(allLabels:["Retry dictation",label],enabledLabels:["Retry dictation"]))
        }
        XCTAssertFalse(DictationReadiness.canStart(allLabels:[],enabledLabels:[]))
    }
    func testFailureRecoveryDoesNotReportSuccessfulTranscriptAndRetryAllowsDrafts() {
        var progress=TranscriptionProgress();progress.begin();progress.observe(.failed)
        progress.observe(.idle);progress.observe(.unavailable);progress.observe(.idle)
        XCTAssertEqual(progress.state,.failed)
        progress.observe(.idle)
        XCTAssertEqual(progress.state,.idle)
        progress.begin();progress.observe(.failed);progress.observe(.busy)
        XCTAssertEqual(progress.state,.transcribing)
        XCTAssertTrue(progress.state.permitsComposerCommands)
    }
    func testBusyAndUnavailableReadsCannotCompleteTranscription() {
        var progress=TranscriptionProgress();progress.begin()
        progress.observe(.busy);progress.observe(.idle)
        XCTAssertEqual(progress.state,.transcribing)
        XCTAssertTrue(progress.needsIdleConfirmation)
        progress.observe(.unavailable)
        XCTAssertFalse(progress.needsIdleConfirmation)
        progress.observe(.idle)
        XCTAssertEqual(progress.state,.transcribing)
        progress.observe(.idle)
        XCTAssertEqual(progress.state,.ready)
        XCTAssertFalse(progress.needsIdleConfirmation)
    }
    func testReadyNoticeExpiresPromptlyWithoutChangingTranscriptionState() {
        let now=Date(timeIntervalSince1970:100)
        var progress=TranscriptionProgress();progress.begin()
        progress.advance(now:now.addingTimeInterval(10))
        XCTAssertEqual(progress.state,.transcribing)
        progress.observe(.idle,now:now);progress.observe(.idle,now:now)
        progress.advance(now:now.addingTimeInterval(0.3))
        XCTAssertEqual(progress.state,.ready)
        progress.advance(now:now.addingTimeInterval(0.35))
        XCTAssertEqual(progress.state,.idle)
        XCTAssertEqual(TouchPresentation.headline(connected:true,status:BridgeStatus(codexForeground:true,dictation:progress.state)),"Ready")
    }
    func testTranscriptionFailureAndTimeoutRemainDistinctFromReady() {
        var timeout=TranscriptionProgress();timeout.begin();timeout.expire()
        XCTAssertEqual(timeout.state,.unknown)
        timeout.observe(.idle);timeout.observe(.idle)
        XCTAssertEqual(timeout.state,.unknown)
        var failure=TranscriptionProgress();failure.begin();failure.observe(.failed)
        XCTAssertEqual(failure.state,.failed)
    }
    func testSharedHeroPrioritizesActiveGestureThenTranscriptionThenForeground() {
        let away=BridgeStatus(codexForeground:false,dictation:.idle)
        XCTAssertEqual(TouchPresentation.headline(connected:true,status:away),"Bring Codex\nto front")
        XCTAssertEqual(TouchPresentation.headline(connected:true,phase:.recording,status:away),"Recording")
        let processing=BridgeStatus(codexForeground:false,dictation:.transcribing)
        XCTAssertEqual(TouchPresentation.headline(connected:true,status:processing),"Transcribing")
        XCTAssertEqual(TouchPresentation.headline(connected:true,phase:.recording,status:processing),"Transcribing")
        XCTAssertEqual(TouchPresentation.instruction(connected:true,phase:.recording,status:processing),"Preparing your text in Codex")
        let ready=BridgeStatus(codexForeground:true,dictation:.ready)
        XCTAssertEqual(TouchPresentation.headline(connected:true,status:ready),"Transcript Done")
        XCTAssertEqual(TouchPresentation.headline(connected:false,status:ready),"")
    }
    func testStatusRoundTripCarriesNoTranscriptAndRetainsRecordingIdentity() throws {
        let status=BridgeStatus(codexForeground:false,dictation:.transcribing,recordingID:UUID())
        let receipt=WakeReceipt(id:UUID(),outcome:.status,message:"",status:status)
        let data=try JSONEncoder().encode(receipt)
        XCTAssertEqual(try JSONDecoder().decode(WakeReceipt.self,from:data),receipt)
        let request=WakeRequest(action:.getStatus)
        XCTAssertEqual(try JSONDecoder().decode(WakeRequest.self,from:JSONEncoder().encode(request)),request)
    }
    func testRepeatedStatusQueryReadsCurrentStateInsteadOfReplayingCachedResult() async {
        actor Counter {
            var value=0
            func next() -> String { value+=1;return String(value) }
        }
        let counter=Counter()
        let service=WakeService { request in WakeReceipt(id:request.id,outcome:.status,message:await counter.next()) }
        let query=WakeRequest(action:.getStatus)
        let first=await service.handle(query),second=await service.handle(query)
        XCTAssertEqual(first.message,"1");XCTAssertEqual(second.message,"2")
    }
}
