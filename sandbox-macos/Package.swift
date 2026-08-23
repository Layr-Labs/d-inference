// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "DarkbloomSandbox",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SandboxCore", targets: ["SandboxCore"]),
        .library(name: "SandboxSecurity", targets: ["SandboxSecurity"]),
        .library(name: "SandboxStorage", targets: ["SandboxStorage"]),
        .library(name: "SandboxRuntime", targets: ["SandboxRuntime"]),
        .library(name: "SandboxRuntimeLume", targets: ["SandboxRuntimeLume"]),
        .library(name: "SandboxRuntimeVZ", targets: ["SandboxRuntimeVZ"]),
        .executable(name: "darkbloom-sandboxd", targets: ["DarkbloomSandboxDaemon"]),
    ],
    targets: [
        .target(
            name: "SandboxCore",
            path: "Sources/SandboxCore"
        ),
        .target(
            name: "SandboxSecurity",
            dependencies: ["SandboxCore"],
            path: "Sources/SandboxSecurity",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(
            name: "SandboxStorage",
            dependencies: ["SandboxCore", "SandboxSecurity"],
            path: "Sources/SandboxStorage"
        ),
        .target(
            name: "SandboxRuntime",
            dependencies: ["SandboxCore"],
            path: "Sources/SandboxRuntime"
        ),
        .target(
            name: "SandboxRuntimeLume",
            dependencies: ["SandboxCore", "SandboxRuntime"],
            path: "Sources/SandboxRuntimeLume"
        ),
        .target(
            name: "SandboxRuntimeVZ",
            dependencies: ["SandboxCore", "SandboxRuntime", "SandboxSecurity"],
            path: "Sources/SandboxRuntimeVZ",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Virtualization"),
            ]
        ),
        .executableTarget(
            name: "DarkbloomSandboxDaemon",
            dependencies: [
                "SandboxCore",
                "SandboxRuntime",
                "SandboxRuntimeLume",
                "SandboxRuntimeVZ",
                "SandboxSecurity",
                "SandboxStorage",
            ],
            path: "Sources/DarkbloomSandboxDaemon"
        ),
        .testTarget(
            name: "SandboxCoreTests",
            dependencies: ["SandboxCore"],
            path: "Tests/SandboxCoreTests"
        ),
        .testTarget(
            name: "SandboxSecurityTests",
            dependencies: ["SandboxSecurity"],
            path: "Tests/SandboxSecurityTests"
        ),
        .testTarget(
            name: "SandboxStorageTests",
            dependencies: ["SandboxStorage"],
            path: "Tests/SandboxStorageTests"
        ),
        .testTarget(
            name: "SandboxRuntimeTests",
            dependencies: ["SandboxCore", "SandboxRuntime"],
            path: "Tests/SandboxRuntimeTests"
        ),
        .testTarget(
            name: "SandboxRuntimeLumeTests",
            dependencies: ["SandboxCore", "SandboxRuntime", "SandboxRuntimeLume"],
            path: "Tests/SandboxRuntimeLumeTests"
        ),
        .testTarget(
            name: "SandboxRuntimeVZTests",
            dependencies: ["SandboxCore", "SandboxRuntimeVZ"],
            path: "Tests/SandboxRuntimeVZTests"
        ),
        .testTarget(
            name: "DarkbloomSandboxDaemonTests",
            dependencies: ["DarkbloomSandboxDaemon"],
            path: "Tests/DarkbloomSandboxDaemonTests"
        ),
    ]
)
