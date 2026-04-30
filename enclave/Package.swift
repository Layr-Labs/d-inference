// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DarkbloomEnclave",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DarkbloomEnclave", type: .static, targets: ["DarkbloomEnclave"]),
        .executable(name: "darkbloom-enclave", targets: ["DarkbloomEnclaveCLI"]),
    ],
    targets: [
        .target(name: "DarkbloomEnclave"),
        .executableTarget(
            name: "DarkbloomEnclaveCLI",
            dependencies: ["DarkbloomEnclave"]
        ),
        .testTarget(name: "DarkbloomEnclaveTests", dependencies: ["DarkbloomEnclave"]),
    ]
)
