// swift-tools-version: 6.1
import PackageDescription

let package = Package(name: "ClusterRemoteOwnerSlice", platforms: [.macOS(.v14)],
    products: [.library(name: "DarkbloomClusterRemote", targets: ["DarkbloomClusterRemote"])],
    targets: [
        .target(name: "DarkbloomClusterProtocol", path: "upstream/DarkbloomClusterProtocol"),
        .target(name: "DarkbloomClusterRemote", dependencies: ["DarkbloomClusterProtocol"]),
        .testTarget(name: "ClusterRemoteOwnerTests", dependencies: ["DarkbloomClusterRemote", "DarkbloomClusterProtocol"], path: "Tests"),
    ])
