// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreHaptics
import OSLog
import TouchCore

/// iPhone-only playback backend; audio recording and recording heartbeats live elsewhere.
@MainActor
final class CoreHapticDriver: HapticDriver {
    enum Failure: Error { case unsupportedHardware,missingAsset(String) }
    private static let log=Logger(subsystem:"com.deepinteractionlab.trackypady.app",category:"Haptics")
    private let engine: CHHapticEngine
    private var patterns:[HapticCue:CHHapticPattern]=[:]
    private var reversedPatterns:[HapticCue:CHHapticPattern]=[:]
    private var player: (any CHHapticAdvancedPatternPlayer)?
    private var playbackID: UUID?
    var onInterruption: (@MainActor ()->Void)?
    init() throws {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { throw Failure.unsupportedHardware }
        engine=try CHHapticEngine()
        engine.playsHapticsOnly=true
        engine.isAutoShutdownEnabled=true
        // Parse/cache once, not on a touch or heartbeat. Runtime files remain byte-identical copies.
        for cue in HapticCue.allCases {
            do {
                guard let url=Bundle.main.url(forResource:cue.rawValue,withExtension:"ahap",subdirectory:"Haptics") else { throw Failure.missingAsset(cue.rawValue) }
                let data=try AHAPNormalizer.normalize(Data(contentsOf:url))
                let json=try JSONSerialization.jsonObject(with:data) as! [String:Any]
                let dictionary=Dictionary(uniqueKeysWithValues:json.map { (CHHapticPattern.Key(rawValue:$0.key),$0.value) })
                patterns[cue]=try CHHapticPattern(dictionary:dictionary)
                let reversed=try JSONSerialization.jsonObject(with:AHAPReverser.reverse(data)) as! [String:Any]
                reversedPatterns[cue]=try CHHapticPattern(dictionary:Dictionary(uniqueKeysWithValues:reversed.map { (CHHapticPattern.Key(rawValue:$0.key),$0.value) }))
            } catch { Self.log.error("Could not load \(cue.rawValue,privacy:.public): \(String(describing:error),privacy:.public)") }
        }
        engine.resetHandler={ [weak self] in
            Task { @MainActor [weak self] in self?.engineInterrupted() }
        }
        engine.stoppedHandler={ [weak self] reason in
            let code=reason.rawValue
            Task { @MainActor [weak self] in
                Self.log.info("Engine stopped: \(code)")
                self?.engineInterrupted()
            }
        }
        try engine.start()
    }
    private func engineInterrupted() {
        // Reset invalidates players. A future explicit cue can restart the engine;
        // never automatically resume a loop for a previous gesture.
        PhoneTrace.event("haptic engine interrupted")
        playbackID=nil;player=nil
        onInterruption?()
    }
    func play(_ cue: HapticCue,loop: Bool,reversed: Bool,delay: TimeInterval,completion: @escaping @MainActor (Bool)->Void) throws {
        PhoneTrace.event("haptic \(cue.rawValue) loop=\(loop) reversed=\(reversed)")
        guard let pattern=(reversed ? reversedPatterns : patterns)[cue] else { throw Failure.missingAsset(cue.rawValue) }
        stop()
        try engine.start()
        let next=try engine.makeAdvancedPlayer(with:pattern)
        next.loopEnabled=loop
        if loop { next.loopEnd=pattern.duration }
        let id=UUID()
        next.completionHandler={ [weak self] error in
            let success=error == nil
            Task { @MainActor [weak self] in
                guard let self,self.playbackID == id else { return }
                PhoneTrace.event("haptic completed \(cue.rawValue); success=\(success); loop=\(loop)")
                self.player=nil;self.playbackID=nil
                if !success { Self.log.error("Haptic playback failed") }
                completion(success)
            }
        }
        player=next;playbackID=id
        do { try next.start(atTime: delay > 0 ? engine.currentTime + delay : CHHapticTimeImmediate) }
        catch { playbackID=nil;player=nil;throw error }
    }
    func stop() {
        // Clear identity before stopping: stop may itself invoke a completion callback.
        let old=player;playbackID=nil;player=nil
        do { try old?.stop(atTime:CHHapticTimeImmediate) }
        catch { Self.log.debug("Player stop: \(String(describing:error),privacy:.public)") }
    }
}

/// Temporary diagnostic trace: lifecycle metadata only, never audio or composer text.
@MainActor
enum PhoneTrace {
    static func event(_ message: String) {
        let line="[Trackypady] \(Date().ISO8601Format()) uptime=\(String(format:"%.3f",ProcessInfo.processInfo.systemUptime)) \(message)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}
