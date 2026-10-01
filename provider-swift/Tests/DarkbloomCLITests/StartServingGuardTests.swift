import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

// Each test runs its command in a child process (an exit test). The commands
// set up process-wide logging and other one-time state, and the child keeps
// that state out of the test process. Every case stops at a guard before the
// provider would touch launchd, the network, a model or the GPU.

private func fixtureHardware(memoryGb: UInt64) -> HardwareInfo {
    HardwareInfo(
        machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
        memoryGb: memoryGb, memoryAvailableGb: memoryGb,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40, memoryBandwidthGbs: 546)
}

private func fixtureSnapshot(
    models: [ModelInfo],
    hardware: HardwareInfo? = nil,
    configPath: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("start-guard-\(UUID().uuidString).toml")
) -> RuntimeSnapshot {
    RuntimeSnapshot(
        configPath: configPath,
        configFileExists: false,
        config: ProviderConfig(provider: ProviderSettings(name: "start-guard-fixture")),
        hardware: hardware,
        hardwareError: nil,
        models: models)
}

/// Creates a private temporary folder in the child process.
private func makeTemporaryDirectory(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Exits the child with the command's exit code, or 0 when it returned.
/// `exit` skips `defer`, so `cleanup` runs first.
private func exitWithResult(
    cleanup: () -> Void = {},
    _ body: () async throws -> Void
) async throws -> Never {
    var status: Int32 = 0
    do {
        try await body()
    } catch let code as ExitCode {
        status = code.rawValue
    }
    cleanup()
    exit(status)
}

private func text(_ bytes: [UInt8]?) -> String {
    String(decoding: bytes ?? [], as: UTF8.self)
}

@Suite("Start serving guards")
struct StartServingGuardTests {
    @Test("--local and --local-endpoint together are refused after the terms notice")
    func localModesAreExclusive() async {
        let result = await #expect(
            processExitsWith: .failure, observing: [\.standardOutputContent, \.standardErrorContent]
        ) {
            try await exitWithResult {
                var command = try Start.parse(["--local", "--local-endpoint"])
                try await command.run()
            }
        }
        let stdout = text(result?.standardOutputContent)
        let stderr = text(result?.standardErrorContent)
        #expect(stdout.contains(
            "By starting the provider, you agree to the Darkbloom Terms of Service:\n"
                + "  https://darkbloom.dev/terms.html\n"))
        #expect(stderr.contains(
            "--local and --local-endpoint are mutually exclusive: use --local for a coordinator-less "
                + "local server, or --local-endpoint to serve a local endpoint alongside the coordinator."))
    }

    @Test("an idle timeout over seven days is refused, and the launchd child shows no terms notice")
    func idleTimeoutOutOfRange() async {
        let result = await #expect(
            processExitsWith: .failure, observing: [\.standardOutputContent, \.standardErrorContent]
        ) {
            let directory = try makeTemporaryDirectory("start-idle")
            var config = ProviderConfig(provider: ProviderSettings(name: "start-idle-fixture"))
            config.backend.modelCacheDirectory = directory.appendingPathComponent("hub").path
            let configPath = directory.appendingPathComponent("provider.toml")
            try ConfigManager.save(config, to: configPath)
            try await exitWithResult(cleanup: { try? FileManager.default.removeItem(at: directory) }) {
                var command = try Start.parse([
                    "--foreground", "--idle-timeout", "10081", "--config", configPath.path,
                ])
                try await command.run()
            }
        }
        let stdout = text(result?.standardOutputContent)
        let stderr = text(result?.standardErrorContent)
        #expect(!stdout.contains("Terms of Service"))
        #expect(stderr.contains(
            "--idle-timeout: idle window must be between 1 and 10080 minutes (7 days), "
                + "or 0 to keep models loaded."))
    }

    @Test("--local names each model without an engine-v2 adapter and refuses an empty catalog")
    func localRefusesUnsupportedModels() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let start = try Start.parse(["--local", "--no-auth"])
            let snapshot = fixtureSnapshot(models: [
                ModelInfo(id: "fixture/llama", modelType: "llama", sizeBytes: 1, estimatedMemoryGb: 1),
                ModelInfo(id: "fixture/untyped", sizeBytes: 1, estimatedMemoryGb: 1),
            ])
            try await exitWithResult {
                try await start.runLocalStandalone(
                    snapshot: snapshot,
                    config: snapshot.config,
                    runtimeCapabilities: [],
                    bootSecuritySnapshot: BootSecuritySnapshot(macOSMajorVersion: 15, sip: .disabled))
            }
        }
        let stderr = text(result?.standardErrorContent)
        #expect(stderr.contains("WARNING: local boot security needs attention; continuing.\n"))
        #expect(!stderr.contains("Coordinator trust policy"))
        #expect(stderr.contains("  - macOS: macOS 15 is below the recommended macOS 26 (Tahoe) posture"))
        #expect(stderr.contains("    Fix: In recoveryOS, run `csrutil enable`, then restart."))
        #expect(stderr.contains(
            "Skipping fixture/llama: model_type 'llama' has no engine-v2 adapter "
                + "(v0.7.5 serves everything through engine v2)"))
        #expect(stderr.contains("Skipping fixture/untyped: model_type 'unknown' has no engine-v2 adapter"))
        #expect(stderr.contains(
            "No engine-v2-capable models available to serve. "
                + "Download a supported model (gpt-oss / gemma-4 families) and retry."))
    }

    @Test("--local with no local models refuses to start")
    func localRefusesEmptyCatalog() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let start = try Start.parse(["--local"])
            let snapshot = fixtureSnapshot(models: [])
            try await exitWithResult {
                try await start.runLocalStandalone(
                    snapshot: snapshot,
                    config: snapshot.config,
                    runtimeCapabilities: [],
                    bootSecuritySnapshot: BootSecuritySnapshot(macOSMajorVersion: 26, sip: .enabled))
            }
        }
        let stderr = text(result?.standardErrorContent)
        #expect(!stderr.contains("WARNING"))
        #expect(!stderr.contains("Skipping"))
        #expect(stderr.contains("No engine-v2-capable models available to serve."))
    }

    @Test("the launchd child with no matching model warns about boot security and stops")
    func foregroundWithoutModelsStops() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let start = try Start.parse(["--foreground", "--model", "fixture/missing"])
            let snapshot = fixtureSnapshot(
                models: [ModelInfo(id: "fixture/present", modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)])
            try await exitWithResult {
                try await start.runForeground(
                    snapshot: snapshot,
                    hardware: fixtureHardware(memoryGb: 64),
                    config: snapshot.config,
                    coordinatorURL: "wss://coordinator.invalid/ws/provider",
                    runtimeCapabilities: [],
                    bootSecuritySnapshot: BootSecuritySnapshot(macOSMajorVersion: 25, sip: .disabled))
            }
        }
        let stderr = text(result?.standardErrorContent)
        #expect(stderr.contains(
            "WARNING: local boot security needs attention; continuing. "
                + "Coordinator trust policy still controls public routing.\n"))
        #expect(stderr.contains("No models selected.\n"))
    }

    @Test("the daemon install stops when --model or --all leaves nothing eligible")
    func daemonInstallNeedsAnEligibleModel() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardErrorContent]) {
            // A saved account token means the inline login offer returns at once.
            let directory = try makeTemporaryDirectory("start-daemon")
            let tokenPath = directory.appendingPathComponent("auth_token")
            try Data("fixture-token".utf8).write(to: tokenPath)
            setenv("DARKBLOOM_AUTH_TOKEN_PATH", tokenPath.path, 1)

            let gated = ModelRuntimeRequirements.qwen38ConcreteModelID
            let snapshot = fixtureSnapshot(models: [
                ModelInfo(id: "fixture/present", modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1),
                ModelInfo(id: gated, modelType: "qwen3_5", sizeBytes: 1, estimatedMemoryGb: 1),
            ])
            let gatedOnly = fixtureSnapshot(models: [
                ModelInfo(id: gated, modelType: "qwen3_5", sizeBytes: 1, estimatedMemoryGb: 1),
            ])
            let cases: [(arguments: [String], snapshot: RuntimeSnapshot)] = [
                (["--model", "fixture/missing"], snapshot),
                (["--model", gated], snapshot),
                (["--all"], gatedOnly),
            ]
            var refused = 0
            for item in cases {
                var start = try Start.parse(item.arguments)
                do {
                    try await start.launchDaemon(
                        snapshot: item.snapshot,
                        config: item.snapshot.config,
                        coordinatorURL: "wss://coordinator.invalid/ws/provider",
                        configPath: nil,
                        runtimeCapabilities: [])
                } catch let code as ExitCode where code == .failure {
                    refused += 1
                }
            }
            try? FileManager.default.removeItem(at: directory)
            exit(refused == cases.count ? 0 : 1)
        }
        let stderr = text(result?.standardErrorContent)
        #expect(stderr.components(separatedBy: "No models selected.\n").count - 1 == 3)
    }

    @Test("preflight refuses a Mac with less than 8 GB of RAM before any prompt")
    func preflightRefusesLowMemory() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            var start = try Start.parse(["--all"])
            let snapshot = fixtureSnapshot(
                models: [ModelInfo(id: "fixture/present", modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)],
                hardware: fixtureHardware(memoryGb: 4))
            try await exitWithResult {
                try await start.launchDaemon(
                    snapshot: snapshot,
                    config: snapshot.config,
                    coordinatorURL: "wss://coordinator.invalid/ws/provider",
                    configPath: nil,
                    runtimeCapabilities: [])
            }
        }
        let stderr = text(result?.standardErrorContent)
        #expect(stderr.contains("This Mac has 4 GB RAM. At least 8 GB is needed to serve any model.\n"))
        #expect(!stderr.contains("No models selected."))
    }

    @Test("preflight accepts a Mac with enough RAM or unknown hardware")
    func preflightAcceptsEnoughMemory() throws {
        let start = try Start.parse([])
        try start.runPreflightChecks(snapshot: fixtureSnapshot(models: [], hardware: fixtureHardware(memoryGb: 8)))
        try start.runPreflightChecks(snapshot: fixtureSnapshot(models: []))
    }
}

@Suite("Local startup preload")
struct LocalStartupPreloadGateTests {
    @Test("startup preload reports its result, and a stop request cancels the next startup")
    func preloadReportsAndHonorsStop() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let start = try Start.parse(["--local"])
            var config = ProviderConfig(provider: ProviderSettings(name: "preload-fixture"))
            config.backend.startupPreload = true
            config.backend.preloadModels = []
            let ready = await start.runLocalStartupPreload(server: StandaloneServer(), config: config)
            _ = await ProviderTermination.shared.request()
            let afterStop = await start.runLocalStartupPreload(server: StandaloneServer(), config: config)
            exit(ready && !afterStop ? 0 : 1)
        }
        let stdout = text(result?.standardOutputContent)
        #expect(stdout.components(separatedBy: "Startup preload: 0 model(s) loaded\n").count - 1 == 1)
    }
}
