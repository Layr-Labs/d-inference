// swift-tools-version: 6.3
import PackageDescription

// Staged source proposal. Normal provider remains macOS 14; the future native
// JACCL worker must build all dependencies with explicit 26.2 Swift/C++ targets.
let package = Package(
    name: "DarkbloomCluster",
    platforms: [.macOS(.v14)],
    products: [.library(name: "DarkbloomClusterRuntime", targets: ["DarkbloomClusterRuntime"])],
    dependencies: [
        .package(path: "../mlx-swift"),
        .package(path: "../mlx-swift-lm"),
    ],
    targets: [
        .target(name: "DarkbloomClusterRuntime", dependencies: [
            .product(name: "Cmlx", package: "mlx-swift"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        ]),
    ])
