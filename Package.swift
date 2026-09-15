// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Two products share this manifest: the original "WebSearch" CLI (bare `swift run`, Apple
// on-device only) and "VistaNova", a SwiftUI .app built via project.yml/xcodegen — Apple
// on-device plus downloadable MLX open-weight models, picked at runtime, all local (no hosted
// providers). Core and Inference are both declared here as binary targets, straight from
// GitHub Release assets — no dependency on the locallm SDK clone's Components package, which
// used to vend Core. That path only worked on a machine with locallm/ checked out; it's
// gitignored here (a local reference clone, not part of this repo), so a fresh checkout of this
// repo alone couldn't resolve it. This manifest is fully self-contained instead.

struct SDKRelease {
    let url: String
    let checksum: String
}

// 1.0.0-RC.1: fixes all four items in locallm-sdk-feedback.md (session.events tool-call
// arguments/resultSummary, effort: .off no longer throwing, cancelDownload(_:), and — in a later
// refresh of this same tag — `installed` no longer falsely reporting a cancelled/partial download
// as installed) — see that file and docs/vistanova-rc1-fixes.md in the SDK repo for details. Same
// release tag, but the binary (and so the checksum below) was replaced after item 4 landed — if
// you pulled RC.1 before and hit a checksum mismatch, this is why; re-pull. Its own release notes
// describe it as "a VERY early build," so keep an eye out for regressions unrelated to these fixes.
let defaultSDKVersion = "1.0.0-RC.1"

let knownCoreReleases: [String: SDKRelease] = [
    "1.0.0-beta.3": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.3/LocalLMLabSDKCore-1.0.0-beta.3.xcframework.zip",
        checksum: "a49b8bfcde340d8b86bf106d2af2cb9d84f3839a3bc1695016f3952a3fcdfb92"
    ),
    "1.0.0-beta.4": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.4/LocalLMLabSDKCore-1.0.0-beta.4.xcframework.zip",
        checksum: "3ed0e79b6914e6b48b7ae27f3fdda139f71e3d60f603daf54901716c8c972cb3"
    ),
    "1.0.0-RC.1": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-RC.1/LocalLMLabSDKCore-1.0.0-RC.1.xcframework.zip",
        checksum: "deb90fc623d41b1d35a27bae0e77a2a709cdd9083063f36927f927fdef45c550"
    ),
]

// LocalLMLabSDKInference (the MLX runtime) — only VistaNova needs this; the CLI doesn't link it.
let knownInferenceReleases: [String: SDKRelease] = [
    "1.0.0-beta.3": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.3/LocalLMLabSDKInference-1.0.0-beta.3.xcframework.zip",
        checksum: "0e2b3cc522291dd6c0afdede6ee4516d272ed20b5c22adad68b80893c266800d"
    ),
    "1.0.0-beta.4": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.4/LocalLMLabSDKInference-1.0.0-beta.4.xcframework.zip",
        checksum: "fa8feb19883f9a465a69f39d756f1b41b515c8298c891b06fef5da5b81b2a03c"
    ),
    "1.0.0-RC.1": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-RC.1/LocalLMLabSDKInference-1.0.0-RC.1.xcframework.zip",
        checksum: "ee466de78509f1bf2d59d78584dccf30b720694402e55c8df3e1d620f29afe48"
    ),
]

func failManifest(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let requestedSDKVersion = ProcessInfo.processInfo.environment["LOCALLM_SDK_VERSION"] ?? defaultSDKVersion

guard let coreRelease = knownCoreReleases[requestedSDKVersion] else {
    failManifest("""
    error: Unknown LOCALLM_SDK_VERSION "\(requestedSDKVersion)".
    Known versions: \(knownCoreReleases.keys.sorted().joined(separator: ", "))
    """)
}
guard let inferenceRelease = knownInferenceReleases[requestedSDKVersion] else {
    failManifest("""
    error: Unknown LOCALLM_SDK_VERSION "\(requestedSDKVersion)".
    Known versions: \(knownInferenceReleases.keys.sorted().joined(separator: ", "))
    """)
}

let package = Package(
    name: "WebSearch",
    platforms: [.macOS("27.0")],
    products: [
        // Vend both as library products so the Xcode project (project.yml) can depend on them by
        // name. `swift build`/`swift run WebSearch` doesn't need this.
        .library(name: "LocalLMLabSDKCore", targets: ["LocalLMLabSDKCore"]),
        .library(name: "LocalLMLabSDKInference", targets: ["LocalLMLabSDKInference"])
    ],
    targets: [
        .binaryTarget(
            name: "LocalLMLabSDKCore",
            url: coreRelease.url,
            checksum: coreRelease.checksum
        ),
        .binaryTarget(
            name: "LocalLMLabSDKInference",
            url: inferenceRelease.url,
            checksum: inferenceRelease.checksum
        ),
        .executableTarget(
            name: "WebSearch",
            dependencies: ["LocalLMLabSDKCore"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
            ]
        )
    ]
)
