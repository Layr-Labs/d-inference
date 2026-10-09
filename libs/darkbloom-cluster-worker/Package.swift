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
    ],
    dependencies: [
        .package(path: "../darkbloom-cluster"),
        .package(path: "../mlx-swift"),
    ],
    targets: [
        .executableTarget(name: "DarkbloomClusterWorker", dependencies: [
            .product(name: "DarkbloomClusterBootstrap", package: "darkbloom-cluster"),
            .product(name: "DarkbloomClusterRuntime", package: "darkbloom-cluster"),
            .product(name: "DarkbloomClusterProtocol", package: "darkbloom-cluster"),
        ]),
        .testTarget(name: "DarkbloomClusterWorkerTests", dependencies: [
            "DarkbloomClusterWorker",
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
