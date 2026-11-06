// swift-tools-version: 6.1
import PackageDescription

// Provider-facing control modules stay independent of MLX and the separately
// built native RDMA worker. The normal provider retains its macOS 14 minimum.
let package = Package(
    name: "DarkbloomCluster",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DarkbloomClusterBootstrap", targets: ["DarkbloomClusterBootstrap"]),
        .library(name: "DarkbloomClusterProtocol", targets: ["DarkbloomClusterProtocol"]),
        .library(name: "DarkbloomClusterSecurity", targets: ["DarkbloomClusterSecurity"]),
        .library(name: "DarkbloomClusterProcess", targets: ["DarkbloomClusterProcess"]),
        .library(name: "DarkbloomClusterRuntime", targets: ["DarkbloomClusterRuntime"]),
        .library(name: "DarkbloomClusterRemote", targets: ["DarkbloomClusterRemote"]),
    ],
    dependencies: [
        .package(path: "../mlx-swift"),
        .package(path: "../mlx-swift-lm"),
    ],
    targets: [
        .target(name: "DarkbloomClusterBootstrap"),
        .target(name: "DarkbloomClusterProtocol"),
        .target(name: "DarkbloomClusterSecurity"),
        .target(name: "DarkbloomClusterProcess", dependencies: ["DarkbloomClusterProtocol"]),
        .target(name: "DarkbloomClusterRemote", dependencies: ["DarkbloomClusterProtocol", "DarkbloomClusterProcess", "DarkbloomClusterBootstrap"]),
        .target(name: "DarkbloomClusterRuntime", dependencies: [
            "DarkbloomClusterProtocol", "DarkbloomClusterBootstrap",
            .product(name: "Cmlx", package: "mlx-swift"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        ]),
        .testTarget(name: "DarkbloomClusterRemoteTests",
            dependencies: ["DarkbloomClusterRemote", "DarkbloomClusterProtocol"]),
        .testTarget(name: "DarkbloomClusterRuntimeTests",
            dependencies: ["DarkbloomClusterRuntime", "DarkbloomClusterProtocol"]),
    ]
)
