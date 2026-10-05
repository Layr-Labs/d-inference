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

private func fixtureSnapshot(models: [ModelInfo], hardware: HardwareInfo? = nil) -> RuntimeSnapshot {
    RuntimeSnapshot(
        configPath: FileManager.default.temporaryDirectory
            .appendingPathComponent("start-guard-\(UUID().uuidString).toml"),
        configFileExists: false,
        config: ProviderConfig(provider: ProviderSettings(name: "start-guard-fixture")),
        hardware: hardware,
        hardwareError: nil,
        models: models)
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
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("start-idle-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
