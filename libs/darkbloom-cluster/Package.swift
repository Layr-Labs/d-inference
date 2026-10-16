// swift-tools-version: 6.1
import PackageDescription

// Private cluster-foundation staging slice 1: membership/protocol identity and
// the authenticated encrypted record channel. MLX-free, macOS 14, default-off:
// no production target depends on this package yet.
let package = Package(
    name: "DarkbloomCluster",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DarkbloomClusterSecurity", targets: ["DarkbloomClusterSecurity"]),
        .library(name: "DarkbloomClusterProtocol", targets: ["DarkbloomClusterProtocol"]),
        .library(name: "DarkbloomClusterBootstrap", targets: ["DarkbloomClusterBootstrap"]),
        .library(name: "DarkbloomClusterProcess", targets: ["DarkbloomClusterProcess"]),
        .library(name: "DarkbloomClusterRemote", targets: ["DarkbloomClusterRemote"]),
        .library(name: "DarkbloomClusterRuntime", targets: ["DarkbloomClusterRuntime"]),
        .library(name: "DarkbloomClusterPlacement", targets: ["DarkbloomClusterPlacement"]),
    ],
    dependencies: [
        // Pinned Darkbloom MLX build (same submodule the provider compiles);
        // used only by the Runtime target, never by the control modules or
        // the provider's normal dependency path.
        .package(path: "../mlx-swift"),
        .package(path: "../mlx-swift-lm"),
    ],
    targets: [
        .target(name: "DarkbloomClusterSecurity", dependencies: ["DarkbloomClusterBootstrap"]),
        .target(name: "DarkbloomClusterProtocol"),
        .target(name: "DarkbloomClusterBootstrap"),
        // Placement from detected hardware: device profile, model layout, speed
        // estimate and the planner. Foundation only, so the provider can plan
        // without linking the MLX runtime.
        .target(name: "DarkbloomClusterPlacement", dependencies: ["DarkbloomClusterProtocol"]),
        .target(name: "DarkbloomClusterProcess", dependencies: ["DarkbloomClusterProtocol"]),
        .target(name: "DarkbloomClusterRemote", dependencies: ["DarkbloomClusterProtocol", "DarkbloomClusterProcess", "DarkbloomClusterBootstrap", "DarkbloomClusterSecurity"]),
        // Staged subset: the model-free closure plus tensor-level
        // verification (safe tensor descriptors/reads, selection, local
        // correctness storage, model parameter layout). No GPU group
        // creation or distributed backend is staged. Qwen loading/resident
        // runtime, Transport and Generation remain unstaged.
        .target(name: "DarkbloomClusterRuntime", dependencies: [
            "DarkbloomClusterProtocol",
            "DarkbloomClusterSecurity",
            "DarkbloomClusterPlacement",
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "Cmlx", package: "mlx-swift"),
        ]),
        .testTarget(name: "DarkbloomClusterRuntimeTests", dependencies: ["DarkbloomClusterRuntime", "DarkbloomClusterProtocol"]),
        // Transport discovery + contract check (single process). Run manually:
        //   swift run cluster-loopback-check
        .executableTarget(name: "cluster-loopback-check", dependencies: [
            "DarkbloomClusterRuntime", "DarkbloomClusterSecurity",
        ], path: "Sources/LoopbackCheck"),
    ]
)
