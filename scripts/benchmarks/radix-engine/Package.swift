// swift-tools-version: 6.1
import Foundation
import PackageDescription

// The harness source is identical for both builds. Baseline has no hybrid
// construction API, so only the candidate's cache configuration is conditional.
let root = ProcessInfo.processInfo.environment["RADIX_SOURCE_ROOT"]!
let candidate = ProcessInfo.processInfo.environment["RADIX_CANDIDATE_BUILD"] == "1"
let package = Package(
    name: "RadixEngineBenchmark",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: root + "/provider-swift"),
        .package(path: root + "/libs/mlx-swift"),
        .package(path: root + "/libs/mlx-swift-lm"),
    ],
    targets: [.executableTarget(
        name: "radix-engine",
        dependencies: [
            .product(name: "ProviderCore", package: "provider-swift"),
            .product(name: "ProviderCoreFoundation", package: "provider-swift"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXVLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        ],
        swiftSettings: candidate ? [.define("RADIX_CANDIDATE")] : []
    ), .testTarget(
        name: "RadixEngineBenchmarkTests", dependencies: ["radix-engine"],
        swiftSettings: candidate ? [.define("RADIX_CANDIDATE")] : []
    )]
)
