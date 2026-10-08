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
    ],
    targets: [
        .target(name: "DarkbloomClusterSecurity", dependencies: ["DarkbloomClusterBootstrap"]),
        .target(name: "DarkbloomClusterProtocol"),
        .target(name: "DarkbloomClusterBootstrap"),
        .target(name: "DarkbloomClusterProcess", dependencies: ["DarkbloomClusterProtocol"]),
        .target(name: "DarkbloomClusterRemote", dependencies: ["DarkbloomClusterProtocol", "DarkbloomClusterProcess", "DarkbloomClusterBootstrap", "DarkbloomClusterSecurity"]),
    ]
)
