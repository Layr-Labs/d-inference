// swift-tools-version: 6.1
import PackageDescription

// Shared libraries keep the provider's macOS 14 minimum. The native executable
// has its own sibling package with a macOS 26.2 deployment target.
let package = Package(
    name: "DarkbloomCluster",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DarkbloomClusterRuntime", targets: ["DarkbloomClusterRuntime"]),
        .library(name: "DarkbloomClusterProtocol", targets: ["DarkbloomClusterProtocol"]),
    ],
    dependencies: [
        .package(path: "../mlx-swift"),
        .package(path: "../mlx-swift-lm"),
    ],
    targets: [
        .target(name: "DarkbloomClusterProtocol"),
        .target(name: "DarkbloomClusterRuntime", dependencies: [
            "DarkbloomClusterProtocol",
            .product(name: "Cmlx", package: "mlx-swift"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        ]),
        .testTarget(name: "DarkbloomClusterRuntimeTests",
            dependencies: ["DarkbloomClusterRuntime", "DarkbloomClusterProtocol"]),
    ]
)
