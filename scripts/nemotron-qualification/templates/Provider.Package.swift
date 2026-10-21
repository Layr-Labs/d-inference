// swift-tools-version: 6.1
import PackageDescription
let buildEnvironmentSwiftSettings: [SwiftSetting] = [.define("DARKBLOOM_ENV_DEV")]
let package = Package(name: "NemotronProviderValidation", platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "packages/mlx-swift"),
        .package(path: "packages/mlx-swift-lm"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        // swift-transformers 1.3.0 (2026-03-23) is the first release with
        // `TokenizersBackend` in `TokenizerModel.knownTokenizers`, which is
        // the tokenizer-class string emitted by Qwen 3.5 / Qwen3-VL
        // checkpoints (see PR #296). Sticking on 0.1.x makes Qwen 3.5
        // models fail to load with `.unsupportedTokenizer("TokenizersBackend")`.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        // Direct pin of the Jinja engine that swift-transformers already vends
        // transitively (same source URL; Package.resolved stays at 2.3.5).
        // ProviderCoreFoundation's template-render self-check compiles model
        // chat templates with the exact engine the runtime tokenizer uses, so
        // "renders here" == "renders at request time". Pure Foundation +
        // OrderedCollections — keeps ProviderCoreFoundation Linux-buildable.
        .package(url: "https://github.com/huggingface/swift-jinja.git", exact: "2.3.6"),
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
        // Already resolved transitively at this version; make the transport
        // ownership and embedded-channel test dependencies explicit.
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.99.0"),
        // Test-only: WebSocket upgrade support so the mock coordinator under
        // Tests/ProviderCoreTests/Helpers can host a `/ws/provider` route.
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", exact: "2.6.0"),
    ],
    targets: [
        .target(
            name: "ProviderBuildEnvironment",
            path: "Sources/ProviderBuildEnvironment",
            swiftSettings: buildEnvironmentSwiftSettings
        ),
        .target(
            name: "ProviderAppAttest",
            dependencies: [
                "ProviderBuildEnvironment",
                .product(name: "Sodium", package: "swift-sodium"),
            ],
            path: "Sources/ProviderAppAttest",
            linkerSettings: [.linkedFramework("DeviceCheck"), .linkedFramework("Security"), .linkedLibrary("bsm")]
        ),
        .target(
            name: "ProviderCoreFoundation",
            dependencies: [
                "ProviderBuildEnvironment",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Jinja", package: "swift-jinja"),
            ],
            path: "Sources/ProviderCoreFoundation"
        ),
        .target(
            name: "ProviderMetallibControl",
            path: "Sources/ProviderMetallibControl",
            publicHeadersPath: "include"
        ),
        .target(
            name: "ProviderCore",
            dependencies: [
                "ProviderAppAttest",
                "ProviderBuildEnvironment",
                "ProviderCoreFoundation",
                "ProviderMetallibControl",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLMServer", package: "mlx-swift-lm"),
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "Jinja", package: "swift-jinja"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Sodium", package: "swift-sodium"),
                .product(name: "TOMLKit", package: "TOMLKit"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            path: "Sources/ProviderCore"
        ),
        // Qualification-only loopback runner (scripts/nemotron-qualification/super-runner.md).
        // It exists only in this harness template, never in the shipping provider manifest.
        .executableTarget(name: "NemotronSuperRunner", dependencies: ["ProviderCore",
                .product(name: "MLX", package: "mlx-swift"), .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"), .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"), .product(name: "MLXLMServer", package: "mlx-swift-lm"),
                .product(name: "Hummingbird", package: "hummingbird"), .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")],
            path: "Tests/NemotronSuperRunner"),
        .testTarget(name: "ProviderCoreTests", dependencies: ["ProviderCore", .product(name: "HummingbirdTesting", package: "hummingbird"), .product(name: "MLXLMCommon", package: "mlx-swift-lm")],
            path: "Tests/ProviderCoreTests", sources: ["Server/NemotronSuperImageHTTPRelayTests.swift", "Inference/Vision/NemotronSuperImageDecodeTests.swift", "Inference/Vision/NemotronSuperImageGoldenTests.swift", "Server/NemotronSuperImageFormatHTTPTests.swift", "Inference/Engine/NemotronSuperLocalImageBindingTests.swift", "Server/NemotronSuperLocalHTTPTests.swift", "Server/NemotronSuperLocalHTTPReasoningToolTests.swift", "Server/NemotronSuperLocalHTTPAdmissionTests.swift", "NemotronSuperRecurrentAdmissionTests.swift", "NemotronSuperLocalOutputTests.swift", "NemotronSuperPromptContractTests.swift", "NemotronSuperPromptGoldenTests.swift", "Inference/Engine/NemotronSuperLoadAdmissionTests.swift", "Inference/Engine/NemotronSuperLocalBindingTests.swift", "Inference/Engine/NemotronSuperLocalMTPTests.swift", "Inference/Engine/NemotronSuperLocalMTPBatchedTests.swift", "Inference/Engine/NemotronSuperLocalPrefillTests.swift", "Inference/Engine/NemotronSuperLocalOwnerTests.swift", "Inference/Engine/NemotronSuperLocalPrefixCacheTests.swift", "Inference/Fixtures/NemotronSuperMTPInstalledFixture.swift", "Inference/Fixtures/EngineV2TestStubs.swift", "Inference/Fixtures/NemotronSuperInstalledFixture.swift"])
    ])
