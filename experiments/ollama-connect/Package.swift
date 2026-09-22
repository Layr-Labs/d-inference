// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DarkbloomConnect",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DarkbloomConnect", targets: ["DarkbloomConnect"]),
        .executable(name: "connect-probe", targets: ["ConnectProbe"]),
    ],
    targets: [
        .target(name: "ConnectCore"),
        .executableTarget(name: "DarkbloomConnect", dependencies: ["ConnectCore"]),
        .executableTarget(name: "ConnectProbe", dependencies: ["ConnectCore"]),
        .testTarget(name: "ConnectCoreTests", dependencies: ["ConnectCore"]),
    ]
)
