// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "HostRuntimeCoordination",
    platforms: [.macOS(.v14)],
    products: [.library(name: "HostRuntimeCoordination", targets: ["HostRuntimeCoordination"])],
    targets: [
        .target(name: "HostRuntimeCoordination"),
        .executableTarget(name: "HostRuntimeLockProbe", dependencies: ["HostRuntimeCoordination"]),
        .testTarget(name: "HostRuntimeCoordinationTests", dependencies: ["HostRuntimeCoordination"]),
    ]
)
