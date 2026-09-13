// swift-tools-version: 6.0
import Foundation
import PackageDescription

// WebSearch — a standalone LocalLM Lab SDK CLI, same shape as the SDK's own repo-qa example
// (see locallm/examples/repo-qa/Package.swift): Core linked as a binary xcframework release
// asset, no other SDK modules needed since this app only uses MCPServerManager + MCPTool.

struct SDKRelease {
    let url: String
    let checksum: String
}

let defaultSDKVersion = "1.0.0-beta.4"

let knownSDKReleases: [String: SDKRelease] = [
    "1.0.0-beta.3": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.3/LocalLMLabSDKCore-1.0.0-beta.3.xcframework.zip",
        checksum: "a49b8bfcde340d8b86bf106d2af2cb9d84f3839a3bc1695016f3952a3fcdfb92"
    ),
    "1.0.0-beta.4": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.4/LocalLMLabSDKCore-1.0.0-beta.4.xcframework.zip",
        checksum: "3ed0e79b6914e6b48b7ae27f3fdda139f71e3d60f603daf54901716c8c972cb3"
    ),
]

func failManifest(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let requestedSDKVersion = ProcessInfo.processInfo.environment["LOCALLM_SDK_VERSION"] ?? defaultSDKVersion

guard let sdkRelease = knownSDKReleases[requestedSDKVersion] else {
    failManifest("""
    error: Unknown LOCALLM_SDK_VERSION "\(requestedSDKVersion)".
    Known versions: \(knownSDKReleases.keys.sorted().joined(separator: ", "))
    """)
}

let package = Package(
    name: "WebSearch",
    platforms: [.macOS("26.0")],
    targets: [
        .binaryTarget(
            name: "LocalLMLabSDKCore",
            url: sdkRelease.url,
            checksum: sdkRelease.checksum
        ),
        .executableTarget(
            name: "WebSearch",
            dependencies: ["LocalLMLabSDKCore"],
            linkerSettings: [
                // Same rpath fix repo-qa and code-buddy need for a bare executable target.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
            ]
        )
    ]
)
