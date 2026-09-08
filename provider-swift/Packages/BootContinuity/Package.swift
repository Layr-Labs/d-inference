// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "BootContinuity",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BootContinuity", targets: ["BootContinuity"])],
    targets: [
        .target(name: "BootContinuity"),
        .testTarget(name: "BootContinuityTests", dependencies: ["BootContinuity"]),
    ]
)
