// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Shared release-time recognition for both composer swipe actions.
public enum ComposerSwipe {
    public enum Direction { case up,down }
    public static let minimumTravel=20.0
    public static func direction(x: Double,y: Double,duration: TimeInterval,cancelled: Bool=false) -> Direction? {
        guard !cancelled,x.isFinite,y.isFinite,duration.isFinite,duration>=0,duration<=1.0,
              abs(y)>=minimumTravel,abs(x)<=abs(y) else { return nil }
        return y<0 ? .up : .down
    }
}

/// Held upward swipes remain reserved for Queue, not Steering.
public enum SteeringSwipe {
    public static func qualifies(x: Double,y: Double,duration: TimeInterval,cancelled: Bool=false) -> Bool {
        ComposerSwipe.direction(x:x,y:y,duration:duration,cancelled:cancelled) == .up
    }
}

public enum ComposerShortcut {
    private static func keys(_ value: String) -> Set<String> {
        Set(value.lowercased().split(separator:"+").map {
            switch $0.trimmingCharacters(in:.whitespaces) {
            case "control","ctrl": return "ctrl"
            case "option","alt": return "alt"
            default: return $0.trimmingCharacters(in:.whitespaces)
            }
        })
    }
    public static func isConfigured(_ data: Data,command: String,key: String) -> Bool {
        guard let entries=(try? JSONSerialization.jsonObject(with:data)) as? [[String:Any]] else { return false }
        let desired=keys(key)
        let targets=entries.filter { ($0["command"] as? String) == command }
        return !targets.isEmpty && targets.allSatisfy { ($0["key"] as? String).map { keys($0)==desired } == true }
            && entries.filter { ($0["key"] as? String).map { keys($0)==desired } == true }.allSatisfy { ($0["command"] as? String)==command }
    }
}
public enum SteeringShortcut {
    public static let command="composer.steer"
    public static let key="Ctrl+Alt+Shift+S"
    public static func isConfigured(_ data: Data) -> Bool { ComposerShortcut.isConfigured(data,command:command,key:key) }
}
public enum QueueShortcut {
    public static let command="composer.queue"
    public static let key="Ctrl+Alt+Shift+Q"
    public static func isConfigured(_ data: Data) -> Bool { ComposerShortcut.isConfigured(data,command:command,key:key) }
}
