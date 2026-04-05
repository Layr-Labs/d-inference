// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EigenInference",
    platforms: [.macOS(.v14)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "EigenInference",
            path: "Sources/EigenInference",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "EigenInferenceTests",
            dependencies: ["EigenInference"],
            path: "Tests/EigenInferenceTests"
        ),
    ]
)
