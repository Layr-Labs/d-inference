// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EigenInferenceEnclave",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "EigenInferenceEnclave", type: .static, targets: ["EigenInferenceEnclave"]),
        .executable(name: "eigeninference-enclave", targets: ["EigenInferenceEnclaveCLI"]),
    ],
    targets: [
        .target(name: "EigenInferenceEnclave"),
        .executableTarget(
            name: "EigenInferenceEnclaveCLI",
            dependencies: ["EigenInferenceEnclave"]
        ),
        .testTarget(name: "EigenInferenceEnclaveTests", dependencies: ["EigenInferenceEnclave"]),
    ]
)
