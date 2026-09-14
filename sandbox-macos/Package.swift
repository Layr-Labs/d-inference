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
        .library(name: "SandboxHostControl", targets: ["SandboxHostControl"]),
        .library(name: "SandboxGuestProtocol", targets: ["SandboxGuestProtocol"]),
        .library(name: "SandboxGuestRuntime", targets: ["SandboxGuestRuntime"]),
        .executable(name: "darkbloom-sandbox-guest", targets: ["DarkbloomSandboxGuest"]),
        .executable(name: "darkbloom-sandboxd", targets: ["DarkbloomSandboxDaemon"]),
    ],
    dependencies: [.package(path: "../host-runtime")],
    targets: [
        .target(name: "SandboxGuestProtocol"),
        .target(name: "SandboxGuestRuntime", dependencies: ["SandboxGuestProtocol", "SandboxRuntime"], linkerSettings: [.linkedFramework("Security")]),
        .executableTarget(name: "DarkbloomSandboxGuest", dependencies: ["SandboxGuestRuntime"]),
        // Test-process fixture only; never included in signed sandbox packages.
        .executableTarget(name: "SandboxProcessLifecycleProbe", dependencies: ["SandboxRuntime"]),
        .testTarget(name: "SandboxGuestProtocolTests", dependencies: ["SandboxGuestProtocol"]),
        .testTarget(name: "SandboxGuestRuntimeTests", dependencies: ["SandboxGuestRuntime", "SandboxGuestProtocol"]),
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
            dependencies: [.product(name: "HostRuntimeCoordination", package: "host-runtime"), "SandboxCore", "SandboxRuntime", "SandboxGuestProtocol"],
            path: "Sources/SandboxRuntimeLume",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(
            name: "SandboxHostContextSupport",
            path: "Sources/SandboxHostContextSupport",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("bsm")]
        ),
        .target(
            name: "SandboxRuntimeVZ",
            dependencies: ["SandboxCore", "SandboxRuntime", "SandboxSecurity", "SandboxHostContextSupport"],
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
                .product(name: "HostRuntimeCoordination", package: "host-runtime"),
                "SandboxCore",
                "SandboxRuntime",
                "SandboxRuntimeLume",
                "SandboxRuntimeVZ",
                "SandboxSecurity",
                "SandboxStorage",
                "SandboxHostControl",
                "SandboxHostContextSupport",
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
