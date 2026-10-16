import ArgumentParser
import Foundation
import MLX
@testable import ProviderCore

/// Qualification-only loopback runner for the unpublished Nemotron Super owner.
/// It is an executable of the Nemotron qualification harness template only; the
/// shipping provider manifest has no such product and nothing in ProviderCore
/// installs the image hook. See scripts/nemotron-qualification/super-runner.md.
@main
struct NemotronSuperRunnerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "nemotron-super-runner",
        abstract: "Serve one Nemotron Super owner on 127.0.0.1 with isolated state until SIGINT/SIGTERM.")

    @Option(help: "New or empty directory for runner state, logs, auth token and ready file.")
    var stateDir: String
    @Option(help: "Pinned full checkpoint directory.")
    var checkpoint: String?
    @Flag(help: "Serve the tiny synthetic fixture (tooling validation only).")
    var synthetic = false
    @Option(help: "Pinned chat_template.jinja (default: <checkpoint>/chat_template.jinja; required with --synthetic).")
    var template: String?
    @Option(help: "Inference port on 127.0.0.1 (0 = ephemeral).")
    var port = 0
    @Option(help: "Diagnostics port on 127.0.0.1 (0 = ephemeral).")
    var diagnosticsPort = 0
    @Option(help: "Maximum context tokens (the Super builder accepts at most 16384).")
    var maxContext = 16384
    @Option(help: "max_tokens applied when a request omits it.")
    var defaultMaxTokens = 512
    @Option(help: """
        KV capacity granted to the bridge, GiB (at least 1). Each request's fixed bytes (recurrent \
        state, request workspace, any speculation charge) are carved from it. Default 4; 12 when \
        --engine-env enables DARKBLOOM_NEMOTRON_SUPER_MTP; 1 + 3 x N for \
        DARKBLOOM_NEMOTRON_SUPER_MAX_CONCURRENT=N > 1. The ready file reports the minimum.
        """)
    var kvCapacityGib: Double?
    @Option(help: "Explicit backend/allocator allowance added to the LOAD quote, GiB (unmeasured default).")
    var backendAllowanceGib = 2.0
    @Option(help: "Override the per-token fp16 KV rate used for request reservations.")
    var kvBytesPerToken: Int?
    @Option(help: "Process budget cap fraction; may only lower the provider default (0.90).")
    var capFraction: Double?
    @Option(help: "Memory/ledger sampling interval, milliseconds.")
    var sampleIntervalMs = 50
    @Option(help: "Bound on waiting for in-flight work after a shutdown signal, seconds.")
    var drainTimeoutSeconds = 600
    @Option(help: "Concurrent shard SHA-256 verifications.")
    var verifyParallelism = 4
    @Flag(help: "Check checkpoint identity and configuration only (no shard reads, no GPU), then exit.")
    var preflight = false
    @Option(name: .customLong("engine-env"),
        help: "KEY=VALUE runtime-policy entry passed to the engine (repeatable; used for A/B switches).")
    var engineEnv: [String] = []

    func validate() throws {
        guard synthetic != (checkpoint != nil) else {
            throw ValidationError("pass exactly one of --checkpoint or --synthetic")
        }
        guard !synthetic || template != nil else { throw ValidationError("--synthetic requires --template") }
        guard !preflight || checkpoint != nil else { throw ValidationError("--preflight requires --checkpoint") }
        guard (1...16384).contains(maxContext), (1...maxContext).contains(defaultMaxTokens) else {
            throw ValidationError("need 1 <= --default-max-tokens <= --max-context <= 16384")
        }
        guard kvCapacityGib.map({ $0 >= 1 }) ?? true, backendAllowanceGib > 0, sampleIntervalMs >= 5,
            verifyParallelism >= 1,
            (0...65535).contains(port), (0...65535).contains(diagnosticsPort)
        else { throw ValidationError("invalid capacity, allowance, sampling or port value") }
        if let capFraction, !(capFraction > 0 && capFraction <= UnifiedMemoryCap.defaultCapFraction) {
            throw ValidationError("--cap-fraction must be in (0, \(UnifiedMemoryCap.defaultCapFraction)]")
        }
        guard engineEnv.allSatisfy({ $0.contains("=") }) else {
            throw ValidationError("--engine-env entries must be KEY=VALUE")
        }
    }

    func run() async throws {
        let isolation = try RunnerIsolation.prepare(stateDirectory: stateDir)
        let log = try RunnerEventLog(url: isolation.eventsFile)
        let shutdown = RunnerShutdown(log: log)
        await shutdown.installSignalHandlers()
        let settings = loadSettings()
        if preflight, let checkpoint {
            let inputs = try RunnerCheckpointInputs(directory: URL(fileURLWithPath: checkpoint, isDirectory: true),
                templateURL: template.map { URL(fileURLWithPath: $0) })
            log.emit("preflight", ["checkpoint": inputs.json, "settings": settings.json])
            try isolation.writePreflight(inputs.json)
            return
        }
        log.emit("runner.start", ["pid": .int(Int64(getpid())), "mode": synthetic ? "synthetic" : "checkpoint",
            "build_configuration": .string(Self.buildConfiguration), "settings": settings.json,
            "isolation": isolation.json, "sample_interval_ms": .count(sampleIntervalMs)])

        let budget = GlobalKVCacheBudget(capFraction: capFraction)
        let sampler = RunnerMemorySampler(budget: budget, log: log, interval: .milliseconds(sampleIntervalMs))
        RunnerProcessMemory.resetPeaks()
        await sampler.start()
        let phases = RunnerLoadPhases(log: log)
        log.emit("load.begin", ["memory": RunnerProcessMemory.snapshot(),
            "ledger": RunnerMemorySampler.ledger(budget.memoryHeadroomSnapshot())])
        let loadStart = ContinuousClock.now
        let serving: RunnerServing
        do {
            serving = try await load(settings: settings, isolation: isolation, budget: budget,
                log: log, phases: phases, shutdown: shutdown)
        } catch {
            let outstanding = await budget.outstandingReservedBytes()
            var fields: [String: RunnerJSON] = ["error": .string(String(describing: error)),
                "shutdown_requested": .bool(await shutdown.requested),
                "outstanding_charged_bytes": .bytes(outstanding), "memory": RunnerProcessMemory.snapshot()]
            if let refusal = error as? NemotronSuperLocalBridgeBuilder.UnserviceableGrant {
                fields["kv_grant_refused"] = RunnerKVGrant.json(refusal)
                let hint = RunnerKVGrant.suggestedGib(refusal.minimumGrantBytes)
                    .map { "rerun with --kv-capacity-gib \($0)" } ?? "no serviceable grant is provable"
                FileHandle.standardError.write(Data("NemotronSuperRunner: \(refusal); \(hint)\n".utf8))
            }
            log.emit("load.failed", fields)
            await sampler.stop()
            throw ExitCode(outstanding == 0 ? Exit.loadFailedRetired : Exit.retainedOwnership)
        }
        let loadSeconds = RunnerJSON.seconds(ContinuousClock.now - loadStart)
        let loadWindow = await sampler.resetPeaks()
        log.emit("load.end", ["seconds": loadSeconds, "phases": phases.json, "identity": serving.identity,
            "load_window": loadWindow, "memory": RunnerProcessMemory.snapshot(),
            "ledger": RunnerMemorySampler.ledger(budget.memoryHeadroomSnapshot())])

        let server = RunnerServer(serving: serving, token: isolation.authToken, log: log, sampler: sampler,
            budget: budget)
        await sampler.setContext { await server.contextFields }
        let readyFields: RunnerJSON = [
            "pid": .int(Int64(getpid())), "model_id": .string(NemotronSuperLocalBinding.modelID),
            "build_configuration": .string(Self.buildConfiguration),
            "executable": .string(Bundle.main.executablePath ?? CommandLine.arguments[0]),
            "state_dir": .string(isolation.stateDirectory.path),
            "auth_token_file": .string(isolation.authTokenFile.path),
            "events_file": .string(isolation.eventsFile.path), "identity": serving.identity,
            "settings": settings.json, "sample_interval_ms": .count(sampleIntervalMs),
            "load_seconds": loadSeconds, "load_phases": phases.json,
        ]
        var servedCleanly = true
        if await shutdown.requested {
            log.emit("serve.skipped", ["reason": "shutdown requested during load"])
        } else {
            do {
                let (inferencePort, diagnosticsPort) = try await server.start(port: port,
                    diagnosticsPort: diagnosticsPort, defaultMaxTokens: defaultMaxTokens,
                    status: { readyFields.merging(["context": .object(await server.contextFields)]) },
                    onFailure: { await shutdown.request(.failure($0)) })
                let ready = readyFields.merging([
                    "base_url": .string("http://127.0.0.1:\(inferencePort)"),
                    "diagnostics_url": .string("http://127.0.0.1:\(diagnosticsPort)"),
                ])
                try isolation.writeReady(ready)
                log.emit("serve.ready", ["base_url": .string("http://127.0.0.1:\(inferencePort)"),
                    "diagnostics_url": .string("http://127.0.0.1:\(diagnosticsPort)")])
            } catch {
                await shutdown.request(.failure("listener start failed: \(error)"))
            }
        }

        let reason = await shutdown.wait()
        if case .failure = reason { servedCleanly = false }
        log.emit("shutdown.begin", reason.json.asFields)
        let drained = await server.drain(timeout: .seconds(drainTimeoutSeconds))
        if case .object(let fields) = drained, case .bool(true)? = fields["timed_out"] { servedCleanly = false }
        log.emit("shutdown.drained", drained.asFields)
        let clean = await retire(serving, budget: budget, log: log, sampler: sampler)
        await sampler.stop()
        let code = !clean ? Exit.retainedOwnership : servedCleanly ? 0 : Exit.servingFailed
        log.emit("runner.exit", ["code": .count(Int(code))])
        if code != 0 { throw ExitCode(code) }
    }

    /// 0: retired cleanly after serving; see super-runner.md#shutdown.
    private enum Exit {
        static let loadFailedRetired: Int32 = 2
        static let retainedOwnership: Int32 = 3
        static let servingFailed: Int32 = 4
    }

    private func load(settings: RunnerLoadSettings, isolation: RunnerIsolation, budget: GlobalKVCacheBudget,
                      log: RunnerEventLog, phases: RunnerLoadPhases,
                      shutdown: RunnerShutdown) async throws -> RunnerServing {
        let template = template.map { URL(fileURLWithPath: $0) }
        let checkpoint = checkpoint.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let task = Task {
            if let checkpoint {
                return try await RunnerCheckpointLoad.load(directory: checkpoint, templateURL: template,
                    settings: settings, budget: budget, log: log, phases: phases)
            }
            return try await RunnerSyntheticLoad.load(stateDirectory: isolation.stateDirectory,
                templateURL: template!, settings: settings, budget: budget, log: log, phases: phases)
        }
        await shutdown.setLoadCancellation { task.cancel() }
        if await shutdown.requested { task.cancel() }
        let result = await task.result
        await shutdown.setLoadCancellation(nil)
        return try result.get()
    }

    /// Retirement is clean only when the owner retired natively and the process
    /// ledger holds no charge (ballast already released by drain).
    private func retire(_ serving: RunnerServing, budget: GlobalKVCacheBudget, log: RunnerEventLog,
                        sampler: RunnerMemorySampler) async -> Bool {
        var facts: RunnerJSON
        var retired = true
        do { facts = try await serving.retire() } catch {
            facts = ["error": .string(String(describing: error))]
            retired = false
        }
        let outstanding = await budget.outstandingReservedBytes()
        let clean = retired && outstanding == 0
        log.emit("retirement", ["clean": .bool(clean), "owner_retired": .bool(retired),
            "outstanding_charged_bytes": .bytes(outstanding), "facts": facts,
            "memory": RunnerProcessMemory.snapshot(), "final": await sampler.snapshot()])
        return clean
    }

    private func loadSettings() -> RunnerLoadSettings {
        var environment: [String: String] = [:]
        for entry in engineEnv {
            let parts = entry.split(separator: "=", maxSplits: 1)
            environment[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
        }
        let kvGib = kvCapacityGib ?? Self.defaultKVCapacityGib(engineEnvironment: environment)
        return RunnerLoadSettings(maxContextLength: maxContext, defaultMaxTokens: defaultMaxTokens,
            kvCapacityBytes: Int(kvGib * 1_073_741_824),
            backendAllowanceBytes: Int(backendAllowanceGib * 1_073_741_824),
            kvBytesPerTokenOverride: kvBytesPerToken, capFraction: capFraction, engineEnvironment: environment,
            verifyParallelism: verifyParallelism)
    }

    /// Unmeasured runner defaults. The speculative grant leaves room for the
    /// assistant's per-request charge on top of the plain owner's fixed bytes;
    /// a batched owner carves every request's fixed bytes (up to 2 GiB of
    /// workspace plus recurrent state) from one grant.
    static let plainKVCapacityGib = 4.0
    static let speculativeKVCapacityGib = 12.0
    static let batchedKVCapacityGibPerRequest = 3.0

    /// The grant when `--kv-capacity-gib` is omitted. Malformed engine values
    /// fail at load with the builder's own error; here they keep the plain grant.
    static func defaultKVCapacityGib(engineEnvironment environment: [String: String]) -> Double {
        if environment[NemotronSuperLocalMTP.enabledKey]?.trimmingCharacters(in: .whitespaces) == "1" {
            return speculativeKVCapacityGib
        }
        let requests = (try? NemotronSuperLocalBridgeBuilder.concurrentRequests(
            environment: environment, speculates: false)) ?? 1
        return requests > 1 ? 1 + batchedKVCapacityGibPerRequest * Double(requests) : plainKVCapacityGib
    }

    #if DEBUG
        static let buildConfiguration = "debug"
    #else
        static let buildConfiguration = "release"
    #endif
}
