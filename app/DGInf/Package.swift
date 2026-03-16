// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DGInf",
    platforms: [.macOS(.v14)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "DGInf",
            path: "Sources/DGInf"
        ),
        .testTarget(
            name: "DGInfTests",
            dependencies: ["DGInf"],
            path: "Tests/DGInfTests"
        ),
    ]
)
