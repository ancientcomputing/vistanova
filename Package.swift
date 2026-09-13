// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Two products share this manifest: the original "WebSearch" CLI (bare `swift run`, Apple
// on-device only) and "WebSearchApp", a SwiftUI .app built via project.yml/xcodegen (both
// on-device and hosted providers, picked at runtime). Core + Components come from
// locallm/Components (the SDK's own open-source Components package, which vendors Core as a
// binary) rather than a Core binaryTarget declared here — WebSearchApp's Xcode project opens
// this manifest and Components' manifest in one graph, and two packages declaring a target of
// the same name is a hard SwiftPM error. Same reason examples/model-switch's own Package.swift
// avoids it (see that file's top comment).

struct SDKRelease {
    let url: String
    let checksum: String
}

let defaultSDKVersion = "1.0.0-beta.4"

// LocalLMLabSDKRemote — only WebSearchApp needs this (hosted providers); the CLI doesn't link it.
let knownRemoteReleases: [String: SDKRelease] = [
    "1.0.0-beta.3": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.3/LocalLMLabSDKRemote-1.0.0-beta.3.xcframework.zip",
        checksum: "2b1e401a606c2c34d3e086cf9a2edad9d2c9ca730a3c3840b964f88d9e2e446b"
    ),
    "1.0.0-beta.4": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.4/LocalLMLabSDKRemote-1.0.0-beta.4.xcframework.zip",
        checksum: "a73a06bf04a2dd3b1a15b40770f12c0565f8cbf1a97eaa604317b09e3a860454"
    ),
]

func failManifest(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let requestedSDKVersion = ProcessInfo.processInfo.environment["LOCALLM_SDK_VERSION"] ?? defaultSDKVersion

guard let remoteRelease = knownRemoteReleases[requestedSDKVersion] else {
    failManifest("""
    error: Unknown LOCALLM_SDK_VERSION "\(requestedSDKVersion)".
    Known versions: \(knownRemoteReleases.keys.sorted().joined(separator: ", "))
    """)
}

let package = Package(
    name: "WebSearch",
    platforms: [.macOS("26.0")],
    products: [
        // Vend Remote as a library product so WebSearchApp's Xcode project (project.yml) can
        // depend on it by name. `swift build`/`swift run WebSearch` doesn't need this.
        .library(name: "LocalLMLabSDKRemote", targets: ["LocalLMLabSDKRemote"])
    ],
    dependencies: [
        .package(path: "locallm/Components")
    ],
    targets: [
        .binaryTarget(
            name: "LocalLMLabSDKRemote",
            url: remoteRelease.url,
            checksum: remoteRelease.checksum
        ),
        .executableTarget(
            name: "WebSearch",
            dependencies: [
                .product(name: "LocalLMLabSDKCore", package: "Components")
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
            ]
        )
    ]
)
