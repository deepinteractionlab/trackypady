// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Read packaged metadata, so diagnostics describe the installed app, not a checkout.
public struct BuildIdentity: Sendable {
    public let version: String
    public let build: String
    public let channel: String
    public let commit: String
    public let modified: Bool
    public let buildID: String
    public let manifest: String?

    public init(bundle: Bundle = .main) {
        let info = bundle.infoDictionary ?? [:]
        version = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        build = info["CFBundleVersion"] as? String ?? "Unknown"
        channel = info["TrackypadyBuildChannel"] as? String ?? "unidentified"
        commit = info["TrackypadyGitCommit"] as? String ?? "Unknown"
        modified = info["TrackypadySourceModified"] as? Bool ?? false
        buildID = info["TrackypadyBuildID"] as? String ?? "Unknown"
        manifest = bundle.url(forResource: "BuildManifest", withExtension: "json")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    public var summary: String { "\(version) (\(build)) · \(channel)" }
    public var source: String { String(commit.prefix(7)) + (modified ? " · modified" : "") }
    public var details: String {
        "Trackypady \(summary)\nSource: \(source)\nBuild ID: \(buildID)\n\n" + (manifest ?? "Build manifest unavailable")
    }
}
