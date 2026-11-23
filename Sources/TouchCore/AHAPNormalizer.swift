// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreFoundation

/// Removes the supplied assets' project offset; curve control-point times remain relative.
public enum AHAPNormalizer {
    public enum Failure: Error { case invalidPattern,invalidTime }
    public static func normalize(_ data: Data) throws -> Data {
        guard var json=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              var entries=json["Pattern"] as? [[String:Any]],!entries.isEmpty else { throw Failure.invalidPattern }
        let keys=["Event","Parameter","ParameterCurve"]
        var times:[Double]=[]
        for entry in entries {
            for key in keys {
                if let item=entry[key] as? [String:Any] {
                    guard let number=item["Time"] as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue.isFinite,number.doubleValue>=0 else { throw Failure.invalidTime }
                    times.append(number.doubleValue)
                }
            }
        }
        guard let offset=times.min() else { throw Failure.invalidPattern }
        if offset == 0 { return data }
        for index in entries.indices {
            for key in keys {
                if var item=entries[index][key] as? [String:Any],let time=item["Time"] as? NSNumber {
                    item["Time"]=time.doubleValue-offset
                    entries[index][key]=item
                }
            }
        }
        json["Pattern"]=entries
        return try JSONSerialization.data(withJSONObject:json,options:[.sortedKeys])
    }
}
