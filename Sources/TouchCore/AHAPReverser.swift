// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreFoundation

/// Mirrors the bundled haptic timeline, including continuous control envelopes.
/// Original files are never modified. Audio/envelope forms not used by these
/// assets are rejected rather than silently approximated.
public enum AHAPReverser {
    public enum Failure: Error { case invalidPattern,unsupportedPattern }
    private static func number(_ value: Any?) throws -> Double {
        guard let value=value as? NSNumber,CFGetTypeID(value) != CFBooleanGetTypeID(),value.doubleValue.isFinite else { throw Failure.invalidPattern }
        return value.doubleValue
    }
    public static func reverse(_ data: Data) throws -> Data {
        let normalized=try AHAPNormalizer.normalize(data)
        guard var json=try JSONSerialization.jsonObject(with:normalized) as? [String:Any],
              let entries=json["Pattern"] as? [[String:Any]],!entries.isEmpty else { throw Failure.invalidPattern }
        var duration=0.0
        for entry in entries {
            if let event=entry["Event"] as? [String:Any] {
                let time=try number(event["Time"])
                guard let kind=event["EventType"] as? String,["HapticTransient","HapticContinuous"].contains(kind) else { throw Failure.unsupportedPattern }
                let span=try kind == "HapticContinuous" ? number(event["EventDuration"]) : 0
                guard span>=0 else { throw Failure.invalidPattern }
                let parameters=(event["EventParameters"] as? [[String:Any]]) ?? []
                // DRIP has an equal attack/decay pair. Its native envelope is
                // symmetric and can be retained while mirroring the curves.
                let attack=parameters.first { $0["ParameterID"] as? String == "AttackTime" }
                let decay=parameters.first { $0["ParameterID"] as? String == "DecayTime" }
                if attack != nil || decay != nil {
                    guard let attack,let decay,try number(attack["ParameterValue"]) == number(decay["ParameterValue"]) else { throw Failure.unsupportedPattern }
                }
                for parameter in parameters {
                    guard let id=parameter["ParameterID"] as? String,["HapticIntensity","HapticSharpness","AttackTime","DecayTime"].contains(id) else { throw Failure.unsupportedPattern }
                    _ = try number(parameter["ParameterValue"])
                }
                guard (time+span).isFinite else { throw Failure.invalidPattern }
                duration=max(duration,time+span)
            } else if let curve=entry["ParameterCurve"] as? [String:Any] {
                let time=try number(curve["Time"])
                guard let id=curve["ParameterID"] as? String,["HapticIntensityControl","HapticSharpnessControl"].contains(id),
                      let points=curve["ParameterCurveControlPoints"] as? [[String:Any]],!points.isEmpty else { throw Failure.unsupportedPattern }
                var previous = -Double.infinity
                for point in points {
                    let position=try number(point["Time"])
                    guard position>=0,position>=previous else { throw Failure.invalidPattern }
                    _ = try number(point["ParameterValue"])
                    previous=position
                }
                guard try number(points[0]["Time"]) == 0 else { throw Failure.unsupportedPattern }
                guard (time+previous).isFinite else { throw Failure.invalidPattern }
                duration=max(duration,time+previous)
            } else { throw Failure.unsupportedPattern }
        }
        var reversed:[[String:Any]]=[]
        for var entry in entries {
            if var event=entry["Event"] as? [String:Any] {
                let time=try number(event["Time"])
                let span=try event["EventType"] as? String == "HapticContinuous" ? number(event["EventDuration"]) : 0
                event["Time"]=max(0,duration-time-span)
                entry["Event"]=event
            } else if var curve=entry["ParameterCurve"] as? [String:Any],
                      let points=curve["ParameterCurveControlPoints"] as? [[String:Any]],let last=points.last {
                let time=try number(curve["Time"]),span=try number(last["Time"])
                // All bundled curves cover their full pattern; reject undefined
                // pre/post-curve modifier history for future, different assets.
                guard abs(time)<0.000001,abs(span-duration)<0.000001 else { throw Failure.unsupportedPattern }
                curve["Time"]=max(0,duration-time-span)
                curve["ParameterCurveControlPoints"]=try points.reversed().map { point in
                    var result=point;result["Time"]=max(0,span - (try number(point["Time"])));return result
                }
                entry["ParameterCurve"]=curve
            }
            reversed.append(entry)
        }
        json["Pattern"]=reversed.sorted {
            let a=($0["Event"] ?? $0["ParameterCurve"]) as! [String:Any]
            let b=($1["Event"] ?? $1["ParameterCurve"]) as! [String:Any]
            return (a["Time"] as! NSNumber).doubleValue < (b["Time"] as! NSNumber).doubleValue
        }
        return try JSONSerialization.data(withJSONObject:json,options:[.sortedKeys])
    }
}
