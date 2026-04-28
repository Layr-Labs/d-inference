// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Darkbloom",
    platforms: [.macOS(.v14)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Darkbloom",
            path: "Sources/Darkbloom",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "DarkbloomTests",
            dependencies: ["Darkbloom"],
            path: "Tests/DarkbloomTests"
        ),
    ]
)
