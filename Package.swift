// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Two products share this manifest: the original "WebSearch" CLI (bare `swift run`, Apple
// on-device only) and "WebSearchApp", a SwiftUI .app built via project.yml/xcodegen — Apple
// on-device plus downloadable MLX open-weight models, picked at runtime, all local (no hosted
// providers). Core + Components come from locallm/Components (the SDK's own open-source
// Components package, which vendors Core as a binary) rather than a Core binaryTarget declared
// here — WebSearchApp's Xcode project opens this manifest and Components' manifest in one graph,
// and two packages declaring a target of the same name is a hard SwiftPM error. Same reason
// examples/model-switch's own Package.swift avoids it (see that file's top comment).

struct SDKRelease {
    let url: String
    let checksum: String
}

let defaultSDKVersion = "1.0.0-beta.4"

// LocalLMLabSDKInference (the MLX runtime) — only WebSearchApp needs this; the CLI doesn't link it.
let knownInferenceReleases: [String: SDKRelease] = [
    "1.0.0-beta.3": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.3/LocalLMLabSDKInference-1.0.0-beta.3.xcframework.zip",
        checksum: "0e2b3cc522291dd6c0afdede6ee4516d272ed20b5c22adad68b80893c266800d"
    ),
    "1.0.0-beta.4": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.4/LocalLMLabSDKInference-1.0.0-beta.4.xcframework.zip",
        checksum: "fa8feb19883f9a465a69f39d756f1b41b515c8298c891b06fef5da5b81b2a03c"
    ),
]

func failManifest(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let requestedSDKVersion = ProcessInfo.processInfo.environment["LOCALLM_SDK_VERSION"] ?? defaultSDKVersion

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
        // Vend Inference as a library product so WebSearchApp's Xcode project (project.yml) can
        // depend on it by name. `swift build`/`swift run WebSearch` doesn't need this.
        .library(name: "LocalLMLabSDKInference", targets: ["LocalLMLabSDKInference"])
    ],
    dependencies: [
        .package(path: "locallm/Components")
    ],
    targets: [
        .binaryTarget(
            name: "LocalLMLabSDKInference",
            url: inferenceRelease.url,
            checksum: inferenceRelease.checksum
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
