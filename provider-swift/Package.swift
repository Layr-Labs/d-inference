// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "DarkbloomProvider",
    // macOS 14 (Sonoma) — matches libs/mlx-swift-lm and libs/mlx-swift declared
    // platforms. Keeps the same install base as the legacy Rust provider.
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProviderCoreFoundation", targets: ["ProviderCoreFoundation"]),
        .library(name: "ProviderCore", targets: ["ProviderCore"]),
        .executable(name: "darkbloom", targets: ["darkbloom"]),
        .executable(name: "darkbloom-enclave", targets: ["DarkbloomEnclaveCLI"]),
        .executable(name: "darkbloom-publish", targets: ["darkbloom-publish"]),
    ],
    dependencies: [
        .package(path: "../libs/mlx-swift"),
        .package(path: "../libs/mlx-swift-lm"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        // swift-transformers 1.3.0 (2026-03-23) is the first release with
        // `TokenizersBackend` in `TokenizerModel.knownTokenizers`, which is
        // the tokenizer-class string emitted by Qwen 3.5 / Qwen3-VL
        // checkpoints (see PR #296). Sticking on 0.1.x makes Qwen 3.5
        // models fail to load with `.unsupportedTokenizer("TokenizersBackend")`.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        // EventSource 1.4.x uses a Swift 6.1 traits manifest that enables an
        // AsyncHTTPClient/NIO dependency path in release builds. Xcode 26.4's
        // native SwiftPM builder then drops required transitive C module maps
        // while compiling EventSource. swift-huggingface only needs the core
        // EventSource library here, so pin to the simpler 1.3.0 manifest.
        .package(url: "https://github.com/mattt/EventSource.git", exact: "1.3.0"),
        .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.9.1"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
        // Bumped 2.22.0 -> 2.23.0 to satisfy mlx-swift-lm's MLXLMServer
        // target which declares `from: "2.23.0"` (introduced in upstream
        // PR #26, "Add OpenAI-compatible inference server").
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.23.0"),
        // Test-only: WebSocket upgrade support so the mock coordinator under
        // Tests/ProviderCoreTests/Helpers can host a `/ws/provider` route.
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", exact: "2.6.0"),
    ],
    targets: [
        // ----------------------------------------------------------------
        // ProviderCoreFoundation: Linux-buildable subset containing the
        // model hashing primitives (ModelScanner file discovery,
        // WeightHasher) and the registry manifest types. Has NO Apple-
        // only dependencies (no CryptoKit, no os.Logger, no MLX) so it
        // can be linked into `darkbloom-publish` on Linux GCP VMs.
        // ----------------------------------------------------------------
        .target(
            name: "ProviderCoreFoundation",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ProviderCoreFoundation"
        ),

        // ----------------------------------------------------------------
        // ProviderCore: shared library that holds protocol, hardware,
        // crypto, models, security, telemetry, coordinator client,
        // batch scheduler, and the main ProviderLoop. Linked by both
        // `darkbloom` (provider CLI) and `darkbloom-enclave` (Secure
        // Enclave helper).
        // ----------------------------------------------------------------
        .target(
            name: "ProviderCore",
            dependencies: [
                "ProviderCoreFoundation",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLMServer", package: "mlx-swift-lm"),
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Sodium", package: "swift-sodium"),
                .product(name: "TOMLKit", package: "TOMLKit"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/ProviderCore"
        ),

        // ----------------------------------------------------------------
        // darkbloom: command-line entry point. Subcommands: serve / start /
        // stop / status / doctor / models / login / logout / benchmark /
        // update / verify (Phase 0 fidelity check).
        //
        // The Swift cutover is CLI-only — the legacy `app/EigenInference/`
        // SwiftUI menu bar app has been deleted from the repo. No in-process
        // GUI integration is planned in this migration.
        // ----------------------------------------------------------------
        .executableTarget(
            name: "darkbloom",
            dependencies: [
                "ProviderCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/darkbloom"
        ),

        // ----------------------------------------------------------------
        // darkbloom-enclave: small CLI wrapper around the Secure Enclave
        // identity helpers in ProviderCore (Phase 3 merged the FFI bridge
        // from ../enclave). Used by install.sh to render an attestation
        // blob before the main provider is running. The legacy binary
        // name `eigeninference-enclave` is kept as a symlink in
        // install.sh for backward compatibility with already-installed
        // bundles.
        // ----------------------------------------------------------------
        .executableTarget(
            name: "DarkbloomEnclaveCLI",
            dependencies: [
                "ProviderCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/darkbloom-enclave-cli"
        ),

        // ----------------------------------------------------------------
        // darkbloom-publish: Linux-friendly executable that runs on the
        // GCP publish VM. Subcommands today: `hash` (emit manifest.json
        // for a HuggingFace snapshot directory). Depends only on
        // ProviderCoreFoundation so it can build on Linux without MLX.
        // ----------------------------------------------------------------
        .executableTarget(
            name: "darkbloom-publish",
            dependencies: [
                "ProviderCoreFoundation",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/darkbloom-publish"
        ),

        // ----------------------------------------------------------------
        // Tests — protocol round-trip, hardware detection, crypto interop
        // (incl. NaCl-box golden vectors generated by Go), security posture,
        // batch planner, standalone HTTP server, inference engine, and
        // Phase 6 release-payload shape.
        // ----------------------------------------------------------------
        .testTarget(
            name: "ProviderCoreTests",
            dependencies: [
                "ProviderCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ],
            path: "Tests/ProviderCoreTests"
        ),

        // ----------------------------------------------------------------
        // ProviderCoreFoundationTests — Linux-buildable tests for the
        // hashing primitives, role classification, allow-list regression,
        // subdirectory recursion, and the manifest golden vector.
        // ----------------------------------------------------------------
        .testTarget(
            name: "ProviderCoreFoundationTests",
            dependencies: ["ProviderCoreFoundation"],
            path: "Tests/ProviderCoreFoundationTests"
        ),
    ]
)
