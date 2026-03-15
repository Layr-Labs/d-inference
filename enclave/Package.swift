// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DGInfEnclave",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DGInfEnclave", type: .static, targets: ["DGInfEnclave"]),
        .executable(name: "dginf-enclave", targets: ["DGInfEnclaveCLI"]),
    ],
    targets: [
        .target(name: "DGInfEnclave"),
        .executableTarget(
            name: "DGInfEnclaveCLI",
            dependencies: ["DGInfEnclave"]
        ),
        .testTarget(name: "DGInfEnclaveTests", dependencies: ["DGInfEnclave"]),
    ]
)
