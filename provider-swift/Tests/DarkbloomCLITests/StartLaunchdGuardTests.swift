import ArgumentParser
import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

// These start paths call `runForeground` and `launchDaemon`, which can reach
// launchd code after their guards. Each test runs in a child process (an exit
// test). Inside the child, the launchctl runner records each call and returns
// failure, and the LaunchAgent home folder is a temporary folder. So a
// regressed guard cannot stop, drain or replace a live provider on the Mac
// that runs the tests. The parent checks that no launchctl call changed
// launchd state.

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
            .appendingPathComponent("start-launchd-guard-\(UUID().uuidString).toml"),
        configFileExists: false,
        config: ProviderConfig(provider: ProviderSettings(name: "start-launchd-guard-fixture")),
        hardware: hardware,
        hardwareError: nil,
        models: models)
}

/// Writes each launchctl call to standard error as `launchctl: <arguments>`
/// and returns failure. Nothing is spawned.
private func recordingLaunchctl(_ arguments: [String]) throws -> LaunchctlControl.Output {
    FileHandle.standardError.write(Data("launchctl: \(arguments.joined(separator: " "))\n".utf8))
    return LaunchctlControl.Output(status: 1, stdout: "", stderr: "launchctl is not run in tests")
}

/// Runs `body` with the launchctl runner and the LaunchAgent home folder
/// bound for this task, removes the temporary home folder, and exits the
/// child with the command's exit code, or 0 when it returned. `exit` skips
/// `defer`, so the cleanup runs first.
private func exitIsolated(_ body: () async throws -> Void) async throws -> Never {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("start-launchd-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    var code: Int32 = 0
    do {
        try await LaunchctlControl.$homeDirectoryForTesting.withValue(home) {
            try await LaunchctlControl.$runnerForTesting.withValue(recordingLaunchctl) {
                try await body()
            }
        }
    } catch let exitCode as ExitCode {
        code = exitCode.rawValue
    }
    try? FileManager.default.removeItem(at: home)
    exit(code)
}

private func text(_ bytes: [UInt8]?) -> String {
    String(decoding: bytes ?? [], as: UTF8.self)
}

/// launchctl verbs that change launchd state.
private let changingVerbs: Set<String> = ["bootstrap", "bootout", "kickstart", "enable", "disable", "kill", "load", "unload"]

private func changingLaunchctlCalls(_ stderr: String) -> [String] {
    stderr.split(separator: "\n").filter { line in
        guard line.hasPrefix("launchctl: ") else { return false }
        let verb = line.dropFirst("launchctl: ".count).split(separator: " ").first.map(String.init) ?? ""
        return changingVerbs.contains(verb)
    }.map(String.init)
}

@Suite("Start guards before launchd")
struct StartLaunchdGuardTests {
    @Test("the launchd child with no matching model warns about boot security and stops")
    func foregroundWithoutModelsStops() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let start = try Start.parse(["--foreground", "--model", "fixture/missing"])
            let snapshot = fixtureSnapshot(
                models: [ModelInfo(id: "fixture/present", modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)])
            try await exitIsolated {
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
        #expect(changingLaunchctlCalls(stderr).isEmpty, "\(changingLaunchctlCalls(stderr))")
    }

    @Test("the daemon install stops when --model or --all leaves nothing eligible")
    func daemonInstallNeedsAnEligibleModel() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardErrorContent]) {
            // A saved account token means the inline login offer returns at once.
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("start-daemon-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
            try await exitIsolated {
                // Model selection throws a ValidationError when nothing is
                // eligible. Each refusal is written to standard error.
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
                    } catch let error as ValidationError {
                        FileHandle.standardError.write(Data("refused: \(error.message)\n".utf8))
                        refused += 1
                    }
                }
                try? FileManager.default.removeItem(at: directory)
                if refused != cases.count { throw ExitCode.failure }
            }
        }
        let stderr = text(result?.standardErrorContent)
        #expect(stderr.components(separatedBy: "refused: No models selected.\n").count - 1 == 3)
        #expect(changingLaunchctlCalls(stderr).isEmpty, "\(changingLaunchctlCalls(stderr))")
    }

    @Test("preflight refuses a Mac with less than 8 GB of RAM before any prompt")
    func preflightRefusesLowMemory() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            var start = try Start.parse(["--all"])
            let snapshot = fixtureSnapshot(
                models: [ModelInfo(id: "fixture/present", modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)],
                hardware: fixtureHardware(memoryGb: 4))
            try await exitIsolated {
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
        #expect(!stderr.contains("launchctl: "), "preflight stops before any launchctl call")
    }
}
