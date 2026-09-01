// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "DarkbloomSandbox",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SandboxCore", targets: ["SandboxCore"]),
        .library(name: "SandboxGuestProtocol", targets: ["SandboxGuestProtocol"]),
        .library(name: "SandboxGuestAgentCore", targets: ["SandboxGuestAgentCore"]),
        .library(name: "SandboxSecurity", targets: ["SandboxSecurity"]),
        .library(name: "SandboxStorage", targets: ["SandboxStorage"]),
        .library(name: "SandboxRuntime", targets: ["SandboxRuntime"]),
        .library(name: "SandboxRuntimeLume", targets: ["SandboxRuntimeLume"]),
        .library(name: "SandboxRuntimeVZ", targets: ["SandboxRuntimeVZ"]),
        .library(name: "SandboxHostControl", targets: ["SandboxHostControl"]),
        .executable(name: "darkbloom-sandboxd", targets: ["DarkbloomSandboxDaemon"]),
        .executable(name: "darkbloom-guest-agent", targets: ["DarkbloomGuestAgent"]),
    ],
    targets: [
        .target(
            name: "SandboxCore",
            path: "Sources/SandboxCore"
        ),
        .target(
            name: "SandboxGuestProtocol",
            path: "Sources/SandboxGuestProtocol"
        ),
        .target(
            name: "SandboxGuestAgentCore",
            dependencies: ["SandboxGuestProtocol"],
            path: "Sources/SandboxGuestAgentCore"
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
            dependencies: ["SandboxCore", "SandboxGuestProtocol"],
            path: "Sources/SandboxRuntime"
        ),
        .target(
            name: "SandboxRuntimeLume",
            dependencies: ["SandboxCore", "SandboxRuntime"],
            path: "Sources/SandboxRuntimeLume",
            linkerSettings: [.linkedFramework("Security")]
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
        .target(
            name: "SandboxHostControl",
            dependencies: ["SandboxCore"],
            path: "Sources/SandboxHostControl"
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
                "SandboxHostControl",
            ],
            path: "Sources/DarkbloomSandboxDaemon"
        ),
        .executableTarget(
            name: "DarkbloomGuestAgent",
            dependencies: ["SandboxGuestAgentCore"],
            path: "Sources/DarkbloomGuestAgent"
        ),
        .testTarget(
            name: "SandboxGuestAgentCoreTests",
            dependencies: ["SandboxGuestAgentCore", "SandboxGuestProtocol"],
            path: "Tests/SandboxGuestAgentCoreTests"
        ),
        .testTarget(
            name: "SandboxGuestProtocolTests",
            dependencies: ["SandboxGuestProtocol"],
            path: "Tests/SandboxGuestProtocolTests"
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
            dependencies: [
                "SandboxCore",
                "SandboxRuntime",
                "SandboxGuestProtocol",
                "SandboxGuestAgentCore",
            ],
            path: "Tests/SandboxRuntimeTests"
        ),
        .testTarget(
            name: "SandboxRuntimeLumeTests",
            dependencies: [
                "SandboxCore",
                "SandboxRuntime",
                "SandboxRuntimeLume",
                "SandboxGuestProtocol",
            ],
            path: "Tests/SandboxRuntimeLumeTests"
        ),
        .testTarget(
            name: "SandboxRuntimeVZTests",
            dependencies: ["SandboxCore", "SandboxRuntimeVZ"],
            path: "Tests/SandboxRuntimeVZTests"
        ),
        .testTarget(
            name: "SandboxHostControlTests",
            dependencies: ["SandboxCore", "SandboxHostControl"],
            path: "Tests/SandboxHostControlTests"
        ),
        .testTarget(
            name: "DarkbloomSandboxDaemonTests",
            dependencies: [
                "DarkbloomSandboxDaemon",
                "SandboxCore",
                "SandboxHostControl",
                "SandboxRuntime",
            ],
            path: "Tests/DarkbloomSandboxDaemonTests"
        ),
    ]
)
