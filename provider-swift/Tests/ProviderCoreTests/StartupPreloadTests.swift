/// Startup preload + registration readiness gate tests — live-isolated style:
/// scripted load/self-test/memory closures, temp persistence files, real
/// `ProviderLoop` instances. No model weights, no network, no MLX forward
/// passes.
///
/// Covers:
///   * `StartupPreloader`: sequential order, no-eviction memory admission
///     (largest skipped with WARN when the plan exceeds the budget — never a
///     crash), load-failure continuation, self-test fail-open vs fail-closed,
///     failure telemetry hook.
///   * `ProviderLoop.startupPreloadPlan`: configured order vs persisted
///     biggest-first default, unknown-id filtering, dedup, slot cap.
///   * `ProviderLoop.runStartupPreloadGate`: registration deferred until warm
///     within the timeout; proceeds at the timeout while loads continue in
///     the background; fail-closed self-test retires the model from the
///     advertised set.

import Foundation
import Testing

@testable import ProviderCore

// MARK: - Recording helpers

/// Thread-safe event recorder shared by the scripted closures.
private final class PreloadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _loads: [String] = []
    private var _selfTests: [String] = []
    private var _retired: [String] = []
    private var _telemetry: [(model: String, message: String)] = []
    private var _logs: [String] = []

    func recordLoad(_ id: String) { lock.withLock { _loads.append(id) } }
    func recordSelfTest(_ id: String) { lock.withLock { _selfTests.append(id) } }
    func recordRetire(_ id: String) { lock.withLock { _retired.append(id) } }
    func recordTelemetry(_ model: String, _ message: String) {
        lock.withLock { _telemetry.append((model, message)) }
    }
    func recordLog(_ line: String) { lock.withLock { _logs.append(line) } }

    var loads: [String] { lock.withLock { _loads } }
    var selfTests: [String] { lock.withLock { _selfTests } }
    var retired: [String] { lock.withLock { _retired } }
    var telemetry: [(model: String, message: String)] { lock.withLock { _telemetry } }
    var logs: [String] { lock.withLock { _logs } }
}

/// Minimal async gate (same shape as the ModelPrefetchCoordinatorTests helper,
/// which is file-private there).
private final class PreloadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var permits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty {
                permits += 1
                return nil
            }
            return waiters.removeFirst()
        }
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if permits > 0 {
                    permits -= 1
                    return true
                }
                waiters.append(cont)
                return false
            }
            if resumeNow { cont.resume() }
        }
    }
}

private enum PreloadStubError: Error, LocalizedError {
    case loadExploded
    case selfTestExploded
    var errorDescription: String? {
        switch self {
        case .loadExploded: return "weights corrupted (stub)"
        case .selfTestExploded: return "decode produced no frames (stub)"
        }
    }
}

private func candidate(_ id: String, requiredGb: Double = 1.0) -> StartupPreloader.Candidate {
    StartupPreloader.Candidate(modelId: id, requiredGb: requiredGb)
}

// MARK: - StartupPreloader (component)

@Suite("StartupPreloader")
struct StartupPreloaderTests {

    private func makeDeps(
        recorder: PreloadRecorder,
        freeMemoryGb: Double = 1_000,
        loadError: @escaping @Sendable (String) -> (any Error)? = { _ in nil },
        selfTest: Bool = false,
        selfTestError: @escaping @Sendable (String) -> (any Error)? = { _ in nil },
        selfTestFailClosed: Bool = false
    ) -> StartupPreloader.Dependencies {
        var selfTestClosure: (@Sendable (String) async throws -> Duration)?
        if selfTest {
            selfTestClosure = { id in
                recorder.recordSelfTest(id)
                if let error = selfTestError(id) { throw error }
                return .milliseconds(5)
            }
        }
        return StartupPreloader.Dependencies(
            freeMemoryGb: { freeMemoryGb },
            load: { id in
                recorder.recordLoad(id)
                if let error = loadError(id) { throw error }
            },
            selfTest: selfTestClosure,
            selfTestFailClosed: selfTestFailClosed,
            retire: { id in recorder.recordRetire(id) },
            onSelfTestFailed: { id, message in recorder.recordTelemetry(id, message) },
            log: { line in recorder.recordLog(line) }
        )
    }

    @Test("loads run sequentially in the given order")
    func loadsSequentiallyInGivenOrder() async {
        let recorder = PreloadRecorder()
        let preloader = StartupPreloader(deps: makeDeps(recorder: recorder))

        let summary = await preloader.run(candidates: [
            candidate("big-26b", requiredGb: 30),
            candidate("mid-8b", requiredGb: 9),
            candidate("small-1b", requiredGb: 2),
        ])

        #expect(recorder.loads == ["big-26b", "mid-8b", "small-1b"])
        #expect(summary.loaded == ["big-26b", "mid-8b", "small-1b"])
        #expect(summary.skippedInsufficientMemory.isEmpty)
        #expect(summary.failed.isEmpty)
    }

    @Test("plan exceeding the memory budget: largest skipped with WARN, rest load, no crash")
    func memoryAdmissionSkipsOversizedCandidate() async {
        let recorder = PreloadRecorder()
        // 8 GB free: the 30 GB model must be skipped WITHOUT evicting anything;
        // the smaller ones still load.
        let preloader = StartupPreloader(deps: makeDeps(recorder: recorder, freeMemoryGb: 8))

        let summary = await preloader.run(candidates: [
            candidate("big-26b", requiredGb: 30),
            candidate("mid-8b", requiredGb: 7.5),
            candidate("small-1b", requiredGb: 2),
        ])

        #expect(summary.skippedInsufficientMemory == ["big-26b"])
        #expect(recorder.loads == ["mid-8b", "small-1b"])
        #expect(summary.loaded == ["mid-8b", "small-1b"])
        let warns = recorder.logs.filter { $0.contains("WARN") && $0.contains("big-26b") }
        #expect(!warns.isEmpty)
    }

    @Test("a failed load logs, is recorded, and does not stop later candidates")
    func loadFailureContinues() async {
        let recorder = PreloadRecorder()
        let preloader = StartupPreloader(
            deps: makeDeps(
                recorder: recorder,
                loadError: { $0 == "broken" ? PreloadStubError.loadExploded : nil }))

        let summary = await preloader.run(candidates: [
            candidate("broken"),
            candidate("healthy"),
        ])

        #expect(summary.failed == ["broken"])
        #expect(summary.loaded == ["healthy"])
        #expect(recorder.loads == ["broken", "healthy"])
    }

    @Test("self-test runs once per LOADED model, not for skipped/failed ones")
    func selfTestRunsPerLoadedModel() async {
        let recorder = PreloadRecorder()
        let preloader = StartupPreloader(
            deps: makeDeps(
                recorder: recorder,
                freeMemoryGb: 8,
                loadError: { $0 == "broken" ? PreloadStubError.loadExploded : nil },
                selfTest: true))

        let summary = await preloader.run(candidates: [
            candidate("too-big", requiredGb: 30),
            candidate("broken", requiredGb: 1),
            candidate("healthy", requiredGb: 1),
        ])

        #expect(recorder.selfTests == ["healthy"])
        #expect(summary.loaded == ["healthy"])
    }

    @Test("self-test failure fail-open: telemetry fires, model stays loaded, no retire")
    func selfTestFailureFailOpen() async {
        let recorder = PreloadRecorder()
        let preloader = StartupPreloader(
            deps: makeDeps(
                recorder: recorder,
                selfTest: true,
                selfTestError: { $0 == "flaky" ? PreloadStubError.selfTestExploded : nil }))

        let summary = await preloader.run(candidates: [candidate("flaky"), candidate("healthy")])

        #expect(summary.selfTestFailed == ["flaky"])
        #expect(summary.loaded == ["flaky", "healthy"])  // fail-open: still advertised
        #expect(summary.retired.isEmpty)
        #expect(recorder.retired.isEmpty)
        #expect(recorder.telemetry.count == 1)
        #expect(recorder.telemetry.first?.model == "flaky")
        #expect(recorder.telemetry.first?.message.contains("no frames") == true)
    }

    @Test("self-test failure fail-closed: model retired and dropped from loaded")
    func selfTestFailureFailClosed() async {
        let recorder = PreloadRecorder()
        let preloader = StartupPreloader(
            deps: makeDeps(
                recorder: recorder,
                selfTest: true,
                selfTestError: { $0 == "flaky" ? PreloadStubError.selfTestExploded : nil },
                selfTestFailClosed: true))

        let summary = await preloader.run(candidates: [candidate("flaky"), candidate("healthy")])

        #expect(summary.selfTestFailed == ["flaky"])
        #expect(summary.retired == ["flaky"])
        #expect(summary.loaded == ["healthy"])
        #expect(recorder.retired == ["flaky"])
        #expect(recorder.telemetry.count == 1)
    }

    @Test("cancellation stops the run between candidates")
    func cancellationStopsRun() async {
        let recorder = PreloadRecorder()
        let gate = PreloadGate()
        let deps = StartupPreloader.Dependencies(
            freeMemoryGb: { 1_000 },
            load: { id in
                recorder.recordLoad(id)
                gate.signal()
                // Park until cancelled.
                while true {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(5))
                }
            },
            log: { line in recorder.recordLog(line) }
        )
        let preloader = StartupPreloader(deps: deps)

        let driver = Task { await preloader.run(candidates: [candidate("first"), candidate("second")]) }
        await gate.wait()
        driver.cancel()
        let summary = await driver.value

        #expect(recorder.loads == ["first"])
        #expect(summary.loaded.isEmpty)
    }
}

// MARK: - ProviderLoop plan + gate

private func preloadModelInfo(_ id: String, memoryGb: Double) -> ModelInfo {
    ModelInfo(
        id: id,
        modelType: "gemma",
        parameters: nil,
        quantization: "4bit",
        sizeBytes: UInt64(memoryGb * 1_000_000_000),
        estimatedMemoryGb: memoryGb
    )
}

private func makePreloadLoop(
    models: [ModelInfo],
    backend: BackendSettings,
    loadedModelsFile: URL? = nil
) async throws -> ProviderLoop {
    let config = ProviderLoopConfig(
        coordinatorURL: "ws://127.0.0.1:0/ignored",
        hardware: HardwareInfo(
            machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
            memoryGb: 128, memoryAvailableGb: 124,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546
        ),
        models: models,
        config: ProviderConfig(
            provider: ProviderSettings(name: "startup-preload-test", memoryReserveGB: 1),
            backend: backend,
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
        )
    )
    let loop = try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
    if let loadedModelsFile {
        await loop.setLoadedModelsFileForTesting(loadedModelsFile)
    } else {
        // Point the default at a throwaway location so plan tests never read
        // the developer machine's real ~/.darkbloom/loaded-models.json.
        await loop.setLoadedModelsFileForTesting(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("darkbloom-preload-tests", isDirectory: true)
                .appendingPathComponent("\(UUID().uuidString).json"))
    }
    // Deterministic admission for gate tests (the real probe reads live memory).
    await loop.setStartupPreloadFreeMemoryOverrideForTesting({ 1_000 })
    return loop
}

@Suite("ProviderLoop startup preload plan")
struct StartupPreloadPlanTests {

    @Test("configured preload_models keeps operator order, filters unknown ids, dedups")
    func planUsesConfiguredOrder() async throws {
        let loop = try await makePreloadLoop(
            models: [
                preloadModelInfo("small-1b", memoryGb: 2),
                preloadModelInfo("big-26b", memoryGb: 30),
            ],
            backend: BackendSettings(
                maxModelSlots: 3,
                preloadModels: ["small-1b", "not-installed", "big-26b", "small-1b"]))

        let plan = await loop.startupPreloadPlanForTesting()

        #expect(plan.map(\.modelId) == ["small-1b", "big-26b"])
        // Admission requirement = weights + serve headroom (strictly more than
        // the raw weights).
        #expect(plan.allSatisfy { $0.requiredGb > 0 })
        let small = try #require(plan.first)
        #expect(small.requiredGb > 2)
    }

    @Test("empty preload_models defaults to the persisted set, biggest first")
    func planDefaultsToPersistedBiggestFirst() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-preload-tests", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        LoadedModelsStore.write(["small-1b", "big-26b"], to: file)

        let loop = try await makePreloadLoop(
            models: [
                preloadModelInfo("small-1b", memoryGb: 2),
                preloadModelInfo("big-26b", memoryGb: 30),
            ],
            backend: BackendSettings(maxModelSlots: 3),
            loadedModelsFile: file)

        let plan = await loop.startupPreloadPlanForTesting()

        #expect(plan.map(\.modelId) == ["big-26b", "small-1b"])
    }

    @Test("plan is capped at max_model_slots")
    func planCapsAtMaxModelSlots() async throws {
        let loop = try await makePreloadLoop(
            models: [
                preloadModelInfo("a", memoryGb: 2),
                preloadModelInfo("b", memoryGb: 2),
            ],
            backend: BackendSettings(
                maxModelSlots: 1,
                preloadModels: ["a", "b"]))

        let plan = await loop.startupPreloadPlanForTesting()

        #expect(plan.map(\.modelId) == ["a"])
    }

    @Test("no persisted set and no configured list means nothing to preload")
    func emptyPlanWhenNoHistory() async throws {
        let loop = try await makePreloadLoop(
            models: [preloadModelInfo("a", memoryGb: 2)],
            backend: BackendSettings())

        let plan = await loop.startupPreloadPlanForTesting()
        #expect(plan.isEmpty)

        let outcome = await loop.runStartupPreloadGateForTesting()
        #expect(outcome == .nothingToPreload)
    }
}

@Suite("ProviderLoop startup preload gate")
struct StartupPreloadGateTests {

    @Test("startup_preload = false disables the gate entirely")
    func gateDisabledByConfig() async throws {
        let loop = try await makePreloadLoop(
            models: [preloadModelInfo("a", memoryGb: 2)],
            backend: BackendSettings(startupPreload: false, preloadModels: ["a"]))

        let outcome = await loop.runStartupPreloadGateForTesting()
        #expect(outcome == .disabled)
    }

    @Test("registration is deferred until warm when the preload beats the timeout")
    func gateWarmWithinTimeout() async throws {
        let recorder = PreloadRecorder()
        let loop = try await makePreloadLoop(
            models: [
                preloadModelInfo("a", memoryGb: 2),
                preloadModelInfo("b", memoryGb: 2),
            ],
            backend: BackendSettings(
                preloadModels: ["a", "b"],
                startupPreloadTimeoutSecs: 30,
                startupSelftest: false))
        await loop.setStartupPreloadLoadOverrideForTesting({ id in
            try await Task.sleep(for: .milliseconds(50))
            recorder.recordLoad(id)
        })

        let outcome = await loop.runStartupPreloadGateForTesting()

        // The gate resolving IS the registration readiness signal: run()
        // creates the coordinator client (and therefore registers) strictly
        // after this call returns.
        #expect(outcome == .warm)
        #expect(recorder.loads == ["a", "b"])
    }

    @Test("gate proceeds at the timeout; loads continue in the background")
    func gateTimesOutAndContinuesInBackground() async throws {
        let recorder = PreloadRecorder()
        let loop = try await makePreloadLoop(
            models: [preloadModelInfo("a", memoryGb: 2)],
            backend: BackendSettings(
                preloadModels: ["a"],
                startupPreloadTimeoutSecs: 1,  // minimum configurable gate
                startupSelftest: false))
        // One 3s load vs a 1s gate: generous margins in both directions so a
        // parallel-suite scheduling stall can't flip the outcome.
        await loop.setStartupPreloadLoadOverrideForTesting({ id in
            try await Task.sleep(for: .seconds(3))
            recorder.recordLoad(id)
        })

        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await loop.runStartupPreloadGateForTesting()
        let gateElapsed = clock.now - start

        // Availability beats perfection: the gate released at ~1s even though
        // ~2s of loading remained.
        #expect(outcome == .timedOut)
        #expect(gateElapsed < .milliseconds(2800))
        #expect(recorder.loads.isEmpty)

        // The driver keeps warming in the background after the gate released.
        var waited = 0
        while recorder.loads.isEmpty, waited < 200 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        #expect(recorder.loads == ["a"])

        // And the driver handle clears once done.
        waited = 0
        while await loop.startupPreloadTaskRunningForTesting(), waited < 200 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        #expect(await loop.startupPreloadTaskRunningForTesting() == false)
    }

    @Test("fail-closed self-test failure retires the model from the advertised set")
    func gateFailClosedSelfTestRetires() async throws {
        let loop = try await makePreloadLoop(
            models: [
                preloadModelInfo("flaky", memoryGb: 2),
                preloadModelInfo("healthy", memoryGb: 2),
            ],
            backend: BackendSettings(
                preloadModels: ["flaky", "healthy"],
                startupPreloadTimeoutSecs: 30,
                startupSelftest: true,
                startupSelftestFailClosed: true))
        await loop.setStartupPreloadLoadOverrideForTesting({ _ in })
        await loop.setStartupSelfTestOverrideForTesting({ id in
            if id == "flaky" { throw PreloadStubError.selfTestExploded }
            return .milliseconds(1)
        })

        let outcome = await loop.runStartupPreloadGateForTesting()

        #expect(outcome == .warm)
        // Registration filters loopConfig.models through the advertised set,
        // so the retired build is never announced to the coordinator.
        #expect(await loop.isModelAdvertised("flaky") == false)
        #expect(await loop.isModelAdvertised("healthy") == true)
    }

    @Test("fail-open (default) self-test failure keeps the model advertised")
    func gateFailOpenSelfTestKeepsModel() async throws {
        let loop = try await makePreloadLoop(
            models: [preloadModelInfo("flaky", memoryGb: 2)],
            backend: BackendSettings(
                preloadModels: ["flaky"],
                startupPreloadTimeoutSecs: 30,
                startupSelftest: true))
        await loop.setStartupPreloadLoadOverrideForTesting({ _ in })
        await loop.setStartupSelfTestOverrideForTesting({ _ in
            throw PreloadStubError.selfTestExploded
        })

        let outcome = await loop.runStartupPreloadGateForTesting()

        #expect(outcome == .warm)
        #expect(await loop.isModelAdvertised("flaky") == true)
    }

    @Test("self-test decode on a model without a live slot fails cleanly")
    func selfTestWithoutSlotThrows() async throws {
        let loop = try await makePreloadLoop(
            models: [preloadModelInfo("a", memoryGb: 2)],
            backend: BackendSettings())

        await #expect(throws: InferenceError.self) {
            _ = try await loop.runStartupSelfTestDecode(modelId: "a")
        }
    }
}
