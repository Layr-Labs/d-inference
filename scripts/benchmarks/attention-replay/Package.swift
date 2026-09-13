// swift-tools-version: 6.1
import Foundation
import PackageDescription

let root = ProcessInfo.processInfo.environment["ATTENTION_REPLAY_SOURCE_ROOT"]!
let package = Package(
    name: "AttentionOperatorReplay",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: root + "/libs/mlx-swift"),
        .package(path: root + "/libs/mlx-swift-lm"),
    ],
    targets: [
        .executableTarget(name: "attention-replay", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        ]),
        .testTarget(name: "AttentionReplayTests", dependencies: ["attention-replay"]),
    ]
)
