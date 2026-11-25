// swift-tools-version: 6.1
import PackageDescription

// Startup hardening that every shipped Darkbloom executable (provider, enclave
// and fan helpers, cluster worker and planner) runs first in `main`. No
// dependencies, so the MLX-free executables and their parallel test lanes can
// link it.
let package = Package(
    name: "DarkbloomProcessHardening",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DarkbloomProcessHardening", targets: ["DarkbloomProcessHardening"]),
    ],
    targets: [
        .target(name: "DarkbloomProcessHardening"),
    ]
)
