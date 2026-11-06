// swift-tools-version: 6.1
import PackageDescription

// The package platform sets the final executable's linker minimum. The native
// build also supplies 26.2 Swift/C++ targets so Cmlx compiles actual JACCL code.
let package = Package(
    name: "DarkbloomClusterWorker",
    platforms: [.macOS("26.2")],
    products: [
        .executable(name: "WindowedRequestStateCheck", targets: ["WindowedRequestStateCheck"]),
        .executable(name: "TargetVerificationSessionCheck", targets: ["TargetVerificationSessionCheck"]),
        .executable(name: "TargetVerificationCheck", targets: ["TargetVerificationCheck"]),
        .executable(name: "MTPTinyForwardCheck", targets: ["MTPTinyForwardCheck"]),
        .executable(name: "MTPSelectedLoadCheck", targets: ["MTPSelectedLoadCheck"]),
        .executable(name: "MTPFactoryCheck", targets: ["MTPFactoryCheck"]),
        .executable(name: "darkbloom-cluster-worker", targets: ["DarkbloomClusterWorker"]),
    ],
    dependencies: [
        .package(path: "../mlx-swift"),
        .package(path: "../mlx-swift-lm"),
        .package(path: "../darkbloom-cluster"),
    ],
    targets: [
        .executableTarget(name: "WindowedRequestStateCheck", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "DarkbloomClusterProcess", package: "darkbloom-cluster"),
            .product(name: "DarkbloomClusterRuntime", package: "darkbloom-cluster"),
        ], path: "Tests/WindowedRequestStateCheck"),
        .executableTarget(name: "TargetVerificationSessionCheck", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "DarkbloomClusterProcess", package: "darkbloom-cluster"),
            .product(name: "DarkbloomClusterRuntime", package: "darkbloom-cluster"),
        ], path: "Tests/TargetVerificationSessionCheck"),
        .executableTarget(name: "TargetVerificationCheck", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "DarkbloomClusterProcess", package: "darkbloom-cluster"),
            .product(name: "DarkbloomClusterRuntime", package: "darkbloom-cluster"),
        ], path: "Tests/TargetVerificationCheck"),
        .executableTarget(name: "MTPTinyForwardCheck", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "DarkbloomClusterRuntime", package: "darkbloom-cluster"),
        ], path: "Tests/MTPTinyForwardCheck"),
        .executableTarget(name: "MTPSelectedLoadCheck", dependencies: [
            .product(name: "DarkbloomClusterBootstrap", package: "darkbloom-cluster"),
            .product(name: "DarkbloomClusterRuntime", package: "darkbloom-cluster"),
            .product(name: "DarkbloomClusterProtocol", package: "darkbloom-cluster"),
            .product(name: "DarkbloomClusterProcess", package: "darkbloom-cluster"),
        ], path: "Tests/MTPSelectedLoadCheck"),
        .executableTarget(name: "MTPFactoryCheck", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        ], path: "Tests/MTPFactoryCheck"),
        .executableTarget(name: "DarkbloomClusterWorker", dependencies: [
            .product(name: "DarkbloomClusterBootstrap", package: "darkbloom-cluster"),
            .product(name: "DarkbloomClusterRuntime", package: "darkbloom-cluster"),
            .product(name: "DarkbloomClusterProtocol", package: "darkbloom-cluster"),
        ]),
        .testTarget(name: "DarkbloomClusterWorkerTests", dependencies: [
            "DarkbloomClusterWorker",
            .product(name: "DarkbloomClusterProtocol", package: "darkbloom-cluster"),
        ]),
    ]
)
