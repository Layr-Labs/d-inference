// swift-tools-version: 6.1
import PackageDescription

// The package platform sets the final executable's linker minimum. The native
// build also supplies 26.2 Swift/C++ targets so Cmlx compiles actual JACCL code.
let package = Package(
    name: "DarkbloomClusterWorker",
    platforms: [.macOS("26.2")],
    products: [
        .executable(name: "LabAuthenticatedRDMABenchmark", targets: ["LabAuthenticatedRDMABenchmark"]),
        .executable(name: "ProtectedCapabilityCheck", targets: ["ProtectedCapabilityCheck"]),
        .executable(name: "darkbloom-cluster-worker", targets: ["DarkbloomClusterWorker"]),
    ],
    dependencies: [
        .package(path: "../darkbloom-cluster"),
    ],
    targets: [
        .executableTarget(name: "LabAuthenticatedRDMABenchmark", dependencies: [
            .product(name: "DarkbloomClusterRuntime", package: "darkbloom-cluster"),
        ], path: "Tests/LabAuthenticatedRDMABenchmark"),
        .executableTarget(name: "ProtectedCapabilityCheck", dependencies: [
            .product(name: "DarkbloomClusterRuntime", package: "darkbloom-cluster"),
            .product(name: "DarkbloomClusterProtocol", package: "darkbloom-cluster"),
        ], path: "Tests/ProtectedCapabilityCheck"),
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
