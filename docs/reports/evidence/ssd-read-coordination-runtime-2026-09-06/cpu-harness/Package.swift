// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SSDCheckpointCPURegression",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MLXLMCommon"),
        .target(name: "ProviderCore", dependencies: ["MLXLMCommon"]),
        .testTarget(name: "ProviderCoreTests", dependencies: ["ProviderCore"]),
    ])
