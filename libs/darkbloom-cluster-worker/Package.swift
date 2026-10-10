// swift-tools-version: 6.1
import PackageDescription

// The package platform sets the final executable's linker minimum. The native
// build also supplies 26.2 Swift/C++ targets so Cmlx compiles actual JACCL code
// (mlx-conditional/jaccl_conditional.cpp selects the stub below 26.2). The
// shared library package and the provider keep macOS 14.
let package = Package(
    name: "DarkbloomClusterWorker",
    platforms: [.macOS("26.2")],
    products: [
        .executable(name: "darkbloom-cluster-worker", targets: ["DarkbloomClusterWorker"]),
        .executable(name: "darkbloom-cluster-collective-check", targets: ["CollectiveCheck"]),
        .executable(name: "darkbloom-cluster-stage-check", targets: ["StageLoadCheck"]),
        .executable(name: "darkbloom-cluster-reference", targets: ["ReferenceCheck"]),
        .executable(name: "darkbloom-cluster-pair-check", targets: ["PairCheck"]),
        .executable(name: "darkbloom-cluster-plan", targets: ["PlacementPlan"]),
    ],
    dependencies: [
        .package(path: "../darkbloom-cluster"),
        .package(path: "../mlx-swift"),
        // Already resolved through mlx-swift-lm; the pin is unchanged. Used for
        // the artifact's own tokenizer in the qualification tools only.
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.2"),
    ],
    targets: [
        .executableTarget(name: "DarkbloomClusterWorker", dependencies: [
            .product(name: "DarkbloomClusterBootstrap", package: "darkbloom-cluster"),
            .product(name: "DarkbloomClusterRuntime", package: "darkbloom-cluster"),
            .product(name: "DarkbloomClusterProtocol", package: "darkbloom-cluster"),
        ]),
        .testTarget(name: "DarkbloomClusterWorkerTests", dependencies: [
            "DarkbloomClusterWorker", "DarkbloomClusterQualification", "DarkbloomClusterPrompt",
            .product(name: "DarkbloomClusterProtocol", package: "darkbloom-cluster"),
            .product(name: "DarkbloomClusterRuntime", package: "darkbloom-cluster"),
        ]),
        // One Mac, one rank, real artifact: verified stage load and release.
        .executableTarget(name: "StageLoadCheck", dependencies: [
            .product(name: "DarkbloomClusterRuntime", package: "darkbloom-cluster"),
        ]),
        // One Mac, no model: this Mac's device profile, an artifact's layout
        // and the placement of a model on two or more devices.
        .executableTarget(name: "PlacementPlan", dependencies: [
            .product(name: "DarkbloomClusterRuntime", package: "darkbloom-cluster"),
        ]),
        // Qualification: requests, reports, the comparator and the pair driver.
        // No MLX; the driver process never touches the GPU or a model.
        .target(name: "DarkbloomClusterQualification", dependencies: [
            .product(name: "DarkbloomClusterProtocol", package: "darkbloom-cluster"),
            .product(name: "DarkbloomClusterProcess", package: "darkbloom-cluster"),
        ]),
        .target(name: "DarkbloomClusterPrompt", dependencies: [
            "DarkbloomClusterQualification",
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        // One Mac, both stages, real artifact: the single-host reference.
        .executableTarget(name: "ReferenceCheck", dependencies: [
            "DarkbloomClusterQualification", "DarkbloomClusterPrompt",
            .product(name: "DarkbloomClusterRuntime", package: "darkbloom-cluster"),
        ]),
        // Request writer, two-rank driver and comparator.
        .executableTarget(name: "PairCheck", dependencies: ["DarkbloomClusterQualification", "DarkbloomClusterPrompt"]),
        // Test-only stand-in for the worker; not a product.
        .executableTarget(name: "PairCheckFakeWorker", dependencies: [
            .product(name: "DarkbloomClusterProtocol", package: "darkbloom-cluster"),
        ]),
        .testTarget(name: "DarkbloomClusterQualificationTests", dependencies: [
            "DarkbloomClusterQualification", "PairCheckFakeWorker",
            .product(name: "DarkbloomClusterProtocol", package: "darkbloom-cluster"),
        ]),
        // Two-rank transport qualification: real collectives, no model.
        .executableTarget(name: "CollectiveCheck", dependencies: [
            .product(name: "DarkbloomClusterRuntime", package: "darkbloom-cluster"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "Cmlx", package: "mlx-swift"),
        ]),
    ]
)
