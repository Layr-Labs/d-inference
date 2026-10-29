// swift-tools-version: 6.1
import PackageDescription

// Provider-facing control modules stay independent of MLX and the separately
// built native RDMA worker. The normal provider retains its macOS 14 minimum.
let package = Package(
    name: "DarkbloomCluster",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DarkbloomClusterProtocol", targets: ["DarkbloomClusterProtocol"]),
        .library(name: "DarkbloomClusterProcess", targets: ["DarkbloomClusterProcess"]),
    ],
    targets: [
        .target(name: "DarkbloomClusterProtocol"),
        .target(name: "DarkbloomClusterProcess", dependencies: ["DarkbloomClusterProtocol"]),
    ]
)
