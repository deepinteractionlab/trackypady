// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
// swift-tools-version: 6.0
import PackageDescription
let package=Package(name:"Trackypady",platforms:[.macOS(.v14),.iOS(.v16)],products:[
    .library(name:"CharacterKit",targets:["CharacterKit"]),
    .library(name:"TouchCore",targets:["TouchCore"]),
    .library(name:"TouchLink",targets:["TouchLink"]),
    .executable(name:"TrackypadyBridge",targets:["TrackypadyBridge"])
],targets:[
    // Shared SwiftUI character renderer.
    .target(name:"CharacterKit", dependencies:["TouchCore"], resources:[.copy("Skins/StudioEyes/StudioEyesAssets")]),
    .target(name:"TouchCore"),
    .target(name:"TouchLink",dependencies:["TouchCore"]),
    .executableTarget(name:"TrackypadyBridge",dependencies:["TouchCore","TouchLink"]),
    .testTarget(name:"TouchTests",dependencies:["TouchCore","TouchLink","CharacterKit",
        .target(name:"TrackypadyBridge",condition:.when(platforms:[.macOS]))])
])
