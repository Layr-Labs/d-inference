import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Actual Qwen modules, native KV backends and production slot assembly.
/// Tiny random weights verify lifecycle/wiring, not released-model throughput.
@Suite("Production Qwen startup calibration", .serialized)
struct ProductionModelCalibrationTests {
    init() { _ = LiveInferenceFixtures.ensureMetallibColocated() }

    @Test("dense and MoE Qwen slots calibrate after every reload without customer work",
        arguments: ["EigenLabs/Qwen3.8-27B-4bit-mtp", "qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8"],
        ["auto", "contiguous"])
    func productionQwenCalibratesWithoutJob(modelID: String, backend: String) async throws {
        var previousEpoch: String?
        for _ in 0..<2 {
            let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
                .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
            }
            let bridge = try await makeQwenBridge(modelID: modelID, backend: backend, budget: budget)
            let before = await bridge.backendSlotCapacity()
            #expect(before.performanceMeasurements?.isolatedPrefill == nil)
            let engine = try #require(await bridge.ownedEngine as? EngineV2)
            #expect(engine.nativeShutdownExecutionContractID == nil,
                "ordinary Qwen must not masquerade as a managed MiMo engine")
            #expect(await bridge.kvBackendKind.rawValue == (backend == "auto" ? "paged" : "contiguous"))
            let started = await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false)
            #expect(started)
            await bridge.awaitProductionCalibration()
            let capacity = await bridge.backendSlotCapacity()
            let measurements = try #require(capacity.performanceMeasurements)
            #expect(measurements.epoch != previousEpoch)
            previousEpoch = measurements.epoch
            #expect(measurements.isolatedPrefill?.sampleCount == 2, "\(measurements)")
            #expect(measurements.decode?.sampleCount == 2)
            #expect((measurements.isolatedPrefill?.tokensPerSecond ?? 0) > 0)
            #expect((measurements.decode?.tokensPerSecond ?? 0) > 0)
            #expect(measurements.workloadBuckets.contains {
                $0.phase == "prefill" && $0.promptTokenBucket == 1_024 && $0.contention == "isolated"
            })
            #expect(await bridge.productionCalibrationWorkCounters() == [0, 0, 0, 0])
            #expect(engine.capacity().activeRequests == 0 && budget.serviceBudget.count == 0)
            #expect(!(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false)))
            await bridge.shutdown()
            #expect(!(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false)))
        }
    }

    @Test("the excluded shape warmup precedes calibration once and trains no rate")
    func shapeWarmupPrecedesCalibrationWithoutEvidence() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }
        let bridge = try await makeQwenBridge(modelID: "qwen3.5-35b-a3b", backend: "auto", budget: budget)
        let engine = try #require(await bridge.ownedEngine as? EngineV2)
        await bridge.setShapeWarmupModeTest(.always)
        #expect(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false))
        await bridge.awaitProductionCalibration()
        #expect(await bridge.shapeWarmupCompletedTest())
        let measurements = try #require(await bridge.backendSlotCapacity().performanceMeasurements)
        #expect(measurements.isolatedPrefill?.sampleCount == 2, "\(measurements)")
        #expect(measurements.decode?.sampleCount == 2)
        #expect(measurements.workloadBuckets.allSatisfy { $0.promptTokenBucket == 1_024 })
        #expect(await bridge.productionCalibrationWorkCounters() == [0, 0, 0, 0])
        // Calibration alone decodes 7 + 31 + 31 rows; the solo (16) and width-2
        // (2 x 12) warmup cells add 15 + 22 more.
        #expect(engine.capacity().decodeRowsTotal >= 69 + 30, "\(engine.capacity().decodeRowsTotal)")
        #expect(engine.capacity().activeRequests == 0 && budget.serviceBudget.count == 0)
        #expect(!(await bridge.startShapeWarmupIfNeeded(requireNominalPosture: false)))
        await bridge.shutdown()
    }

    @Test("a foreground request preempts the shape warmup, which a later session completes")
    func foregroundPreemptsShapeWarmupUntilRetry() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }
        let bridge = try await makeQwenBridge(modelID: "EigenLabs/Qwen3.8-27B-4bit-mtp", backend: "auto",
            budget: budget)
        #expect(await bridge.startShapeWarmupIfNeeded(requireNominalPosture: false))
        // Lands inside the grace pause: the session ends before any warmup step.
        let stream = await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: 64),
            request: ChatCompletionRequest(model: "foreground", messages: [], max_tokens: 4),
            requestId: "foreground-preemption", cacheEnabled: false)
        for await event in stream {
            if case .error(let error) = event { Issue.record("foreground request failed: \(error)") }
        }
        await bridge.awaitProductionCalibration()
        #expect(!(await bridge.shapeWarmupCompletedTest()))
        #expect(!(await bridge.startShapeWarmupIfNeeded(requireNominalPosture: false)),
            "preemption backs off before a retry")
        await bridge.waitForPumpRetirement(requestId: "foreground-preemption")
        #expect(await bridge.startShapeWarmupIfNeeded(requireNominalPosture: false, now: .now + .seconds(3_600)))
        await bridge.awaitProductionCalibration()
        #expect(await bridge.shapeWarmupCompletedTest())
        let measurements = await bridge.backendSlotCapacity().performanceMeasurements
        #expect(measurements?.isolatedPrefill?.sampleCount ?? 0 <= 1, "only the foreground sample")
        await bridge.shutdown()
    }

    @Test("a shape warmup retry resumes after the cells an earlier attempt finished")
    func shapeWarmupRetryResumesAfterFinishedCells() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }
        let bridge = try await makeQwenBridge(modelID: "qwen3.5-35b-a3b", backend: "auto", budget: budget)
        let engine = try #require(await bridge.ownedEngine as? EngineV2)
        // As if a request preempted the width cell after the solo cell finished.
        await bridge.setShapeWarmupModeTest(.always)
        await bridge.setShapeWarmupCellsCompletedTest(1)
        let before = engine.capacity().decodeRowsTotal
        #expect(await bridge.startShapeWarmupIfNeeded(requireNominalPosture: false))
        await bridge.awaitProductionCalibration()
        #expect(await bridge.shapeWarmupCompletedTest())
        // The width-2 cell decodes 2 x 11 rows; rerunning the solo cell adds 15.
        let rows = engine.capacity().decodeRowsTotal - before
        #expect(rows > 0 && rows < 22 + 15, "\(rows)")
        #expect(engine.capacity().activeRequests == 0 && budget.serviceBudget.count == 0)
        await bridge.shutdown()
    }

    @Test("a warm shader-cache probe skips the shape cells and trains no rate")
    func warmShaderCacheProbeSkipsShapeCells() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }
        // The first engine's probes compile the probe kernels in this process,
        // whatever the OS shader cache held.
        let first = try await makeQwenBridge(modelID: "qwen3.5-35b-a3b", backend: "auto", budget: budget)
        await first.setShapeWarmupModeTest(.probed)
        await first.runShapeWarmupBeforeServing()
        #expect(await first.shapeWarmupCompletedTest())
        await first.shutdown()

        let bridge = try await makeQwenBridge(modelID: "qwen3.5-35b-a3b", backend: "auto", budget: budget)
        let engine = try #require(await bridge.ownedEngine as? EngineV2)
        await bridge.setShapeWarmupModeTest(.probed)
        #expect(await bridge.startShapeWarmupIfNeeded(requireNominalPosture: false))
        await bridge.awaitProductionCalibration()
        #expect(await bridge.shapeWarmupCompletedTest())
        let probes = await bridge.shaderCacheProbeTest()
        #expect(probes.cold == false && probes.runs == 2, "\(probes)")
        // Each greedy 2-token probe decodes one row; no shape cell ran.
        #expect(engine.capacity().decodeRowsTotal == 2, "\(engine.capacity().decodeRowsTotal)")
        #expect(await bridge.backendSlotCapacity().performanceMeasurements?.isolatedPrefill == nil)
        #expect(await bridge.productionCalibrationWorkCounters() == [0, 0, 0, 0])
        #expect(engine.capacity().activeRequests == 0 && budget.serviceBudget.count == 0)
        await bridge.shutdown()
    }

    @Test("the startup warmup is awaited before serving and cancelling it leaves the warmup due")
    func startupShapeWarmupIsAwaitedAndCancellable() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }
        let bridge = try await makeQwenBridge(modelID: "EigenLabs/Qwen3.8-27B-4bit-mtp", backend: "auto",
            budget: budget)
        await bridge.setShapeWarmupModeTest(.always)
        let cancelled = Task { await bridge.runShapeWarmupBeforeServing() }
        cancelled.cancel()
        await cancelled.value
        #expect(!(await bridge.shapeWarmupCompletedTest()))
        #expect(await bridge.scheduledShapeWarmupTest() == false)

        let other = try await makeQwenBridge(modelID: "EigenLabs/Qwen3.8-27B-4bit-mtp", backend: "auto",
            budget: budget)
        await other.setShapeWarmupModeTest(.always)
        await other.runShapeWarmupBeforeServing()
        // No grace pause and no session left behind: the caller serves next.
        #expect(await other.shapeWarmupCompletedTest())
        #expect(await other.scheduledShapeWarmupTest() == false)
        #expect(await other.backendSlotCapacity().performanceMeasurements?.isolatedPrefill == nil)
        #expect(budget.serviceBudget.count == 0 && !budget.serviceBudget.idleCalibration.hasSession)
        await bridge.shutdown()
        await other.shutdown()
    }

    @Test("the shape warmup's wall budget includes prompt rendering")
    func shapeWarmupBudgetIncludesPromptRender() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }
        // Sizing the first cell's prompt takes five renders, about 1 s here.
        let bridge = try await makeQwenSlot(modelID: "EigenLabs/Qwen3.8-27B-4bit-mtp", backend: "auto",
            budget: budget, tokenizer: SlowTemplateTokenizer(renderDelay: 0.2)).bridge
        let engine = try #require(await bridge.ownedEngine as? EngineV2)
        await bridge.setShapeWarmupModeTest(.always)
        let steps = engine.capacity().stepsExecuted
        // Under the 1 s step minimum after rendering, though not before it.
        await bridge.runShapeWarmupIfNeeded(requireNominalPosture: false, grace: false, budgetSeconds: 1.5)
        #expect(await bridge.shapeWarmupCompletedTest(), "a spent budget completes the attempt")
        #expect(await bridge.shapeWarmupCellsCompletedTest() == 0)
        #expect(engine.capacity().stepsExecuted == steps, "no cell was submitted")
        #expect(engine.capacity().activeRequests == 0 && budget.serviceBudget.count == 0)
        await bridge.shutdown()
    }

    @Test("shape cells whose rows stop early get other prompts, then the last try is accepted")
    func earlyStoppingShapeCellsRetryBoundedly() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }
        // Every vocabulary token stops generation, so each row ends after its first token.
        let bridge = try await makeQwenSlot(modelID: "qwen3.5-35b-a3b", backend: "auto", budget: budget,
            eosTokenIds: Set(0..<64)).bridge
        let engine = try #require(await bridge.ownedEngine as? EngineV2)
        await bridge.setShapeWarmupModeTest(.always)
        let admits = await bridge._testCounters().admits
        await bridge.runShapeWarmupIfNeeded(requireNominalPosture: false, grace: false)
        #expect(await bridge.shapeWarmupCompletedTest(), "an artifact that always stops early finishes the pass")
        #expect(!(await bridge.shapeWarmupDue))
        // Each try of the solo and width-2 cells admits 1 + 2 rows.
        let tries = ModelCalibrationPolicy.shapeWarmupCellTries
        #expect(await bridge._testCounters().admits - admits == 3 * tries)
        #expect(await bridge.backendSlotCapacity().performanceMeasurements?.isolatedPrefill == nil)
        #expect(engine.capacity().activeRequests == 0 && budget.serviceBudget.count == 0)
        await bridge.shutdown()
    }

    @Test("a served width that grows after a pass reruns only its width cell")
    func widerServedWidthRewarmsOnlyTheWidthCell() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }
        let bridge = try await makeQwenBridge(modelID: "qwen3.5-35b-a3b", backend: "contiguous", budget: budget)
        let engine = try #require(await bridge.ownedEngine as? EngineV2)
        await bridge.setShapeWarmupModeTest(.always)
        let fullGrant = engine.capacity().kvBytesCapacity
        #expect(await bridge.effectiveServingConcurrency == 2)
        // A grant with admissible room for one fixed request workspace serves width 1.
        let overhead = try #require(await bridge.maximumRequestOverheadBytes())
        try #require(overhead > 0, "the hybrid Qwen fixture reserves a fixed per-request workspace")
        let admissibleFraction = Double(engine.admissibleKVBytesCapacity) / Double(fullGrant)
        let narrowGrant = Int((Double(Int(UnifiedMemoryCap.minimumLoadKVBytes) + overhead + overhead / 2)
            / admissibleFraction).rounded(.up))
        await bridge.updateKVBytesCapacity(narrowGrant)
        try #require(await bridge.effectiveServingConcurrency == 1)

        var admits = await bridge._testCounters().admits
        await bridge.runShapeWarmupIfNeeded(requireNominalPosture: false, grace: false)
        #expect(await bridge.shapeWarmupWidthTest() == 1)
        #expect(await bridge._testCounters().admits - admits == 1, "only the solo cell fits width 1")
        #expect(!(await bridge.shapeWarmupDue))

        // The grant grows back (a co-resident model unloaded): width 2 is due.
        await bridge.updateKVBytesCapacity(fullGrant)
        #expect(await bridge.effectiveServingConcurrency == 2)
        #expect(await bridge.shapeWarmupDue)
        admits = await bridge._testCounters().admits
        let rows = engine.capacity().decodeRowsTotal
        #expect(await bridge.startShapeWarmupIfNeeded(requireNominalPosture: false))
        await bridge.awaitProductionCalibration()
        #expect(await bridge.shapeWarmupWidthTest() == 2)
        #expect(await bridge._testCounters().admits - admits == 2, "the solo cell does not rerun")
        // The width-2 cell decodes 2 x 11 rows; a solo rerun would add 15.
        #expect(engine.capacity().decodeRowsTotal - rows == 22, "\(engine.capacity().decodeRowsTotal - rows)")
        #expect(!(await bridge.shapeWarmupDue))

        // Narrowing never lowers the warmed width, so widening again is not due.
        await bridge.updateKVBytesCapacity(narrowGrant)
        #expect(!(await bridge.shapeWarmupDue))
        await bridge.updateKVBytesCapacity(fullGrant)
        #expect(!(await bridge.shapeWarmupDue))
        #expect(await bridge.backendSlotCapacity().performanceMeasurements?.isolatedPrefill == nil)
        #expect(engine.capacity().activeRequests == 0 && budget.serviceBudget.count == 0)
        await bridge.shutdown()
    }

    @Test("a retired standalone warmup session starts no successor once the server drains")
    func standaloneSuccessorWarmupRespectsDrain() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }
        let server = StandaloneServer(config: .init(), models: [], kvBudgetForTesting: budget)
        let first = try await makeQwenSlot(modelID: "EigenLabs/Qwen3.8-27B-4bit-mtp", backend: "auto",
            budget: budget)
        let second = try await makeQwenSlot(modelID: "qwen3.5-35b-a3b", backend: "auto", budget: budget)
        for slot in [first, second] { await slot.bridge.setShapeWarmupModeTest(.always) }
        await server.installShapeWarmupSlots(["a": first, "b": second])
        await server.retryShapeWarmups()
        // Server sessions keep the nominal-posture gate; a hot or low-power Mac starts none.
        if await first.bridge.scheduledShapeWarmupTest() {
            await server.setDrainingForShapeWarmupTest()
            await first.bridge.awaitProductionCalibration()
            #expect(await first.bridge.shapeWarmupCompletedTest())
            // The retired session's successor runs on its own background task.
            let deadline = ContinuousClock.now + .seconds(2)
            var successorStarted = false
            while !successorStarted, ContinuousClock.now < deadline {
                successorStarted = await second.bridge.scheduledShapeWarmupTest()
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!successorStarted, "a draining server must not start the next warmup session")
            #expect(!(await second.bridge.shapeWarmupCompletedTest()))
        }
        await server.removeShapeWarmupSlots()
        #expect(budget.serviceBudget.count == 0 && !budget.serviceBudget.idleCalibration.hasSession)
    }

    private func makeQwenBridge(modelID: String, backend: String,
        budget: GlobalKVCacheBudget) async throws -> EngineV2Bridge {
        try await makeQwenSlot(modelID: modelID, backend: backend, budget: budget).bridge
    }

    private func makeQwenSlot(modelID: String, backend: String, budget: GlobalKVCacheBudget,
        tokenizer: any Tokenizer = ModelCalibrationTokenizer(),
        eosTokenIds: Set<Int> = []) async throws -> StandaloneServer.CachedSlot {
        let experts = modelID.contains("27B") ? 0 : 4
        // Keep tensors small but enough real layers for measured prefill to
        // stay inside the existing 20k TPS plausibility bound. A two-layer toy
        // runs at ~100k TPS and is correctly rejected by serving-rate policy.
        let config = try EngineV2VLMTextExtraction.decodeQwenConfiguration(configData: Data("""
        {"model_type":"qwen3_5","hidden_size":64,"num_hidden_layers":32,
         "intermediate_size":128,"num_attention_heads":1,"num_key_value_heads":1,
         "head_dim":64,"linear_num_value_heads":1,"linear_num_key_heads":1,
         "linear_key_head_dim":64,"linear_value_head_dim":64,"linear_conv_kernel_dim":4,
         "vocab_size":64,"full_attention_interval":2,"num_experts":\(experts),
         "num_experts_per_tok":\(experts > 0 ? 2 : 0),"moe_intermediate_size":64,
         "shared_expert_intermediate_size":64,"mtp_num_hidden_layers":0}
        """.utf8))
        let model: any LanguageModel = experts > 0 ? Qwen35MoEModel(config) : Qwen35Model(config)
        let modelType = experts > 0 ? "qwen3_5_moe" : "qwen3_5"
        let container = ModelContainer(context: .init(configuration: .init(id: modelID),
            model: model, processor: CalibrationFixtureProcessor(), tokenizer: tokenizer))
        let tokenizerHandle = TokenizerHandle(tokenizer)
        let sizing = SlotSizingSnapshot(weightsBytes: 1, fp16KVBytesPerToken: 256,
            maxContextLength: 2_048, defaultMaxTokens: 32)
        let bundle = try await EngineV2SlotFactory.makeProductionBundle(
            modelId: modelID, modelType: modelType, isVLM: false,
            modelDirectory: nil, container: container, tokenizer: tokenizerHandle,
            sizing: sizing,
            kvBytesCapacity: 4 << 30, maxConcurrentRequests: 2, kvBudget: budget,
            kvBackendConfig: backend, weightHash: nil,
            specDecPreparation: .init(artifact: nil, status: .disabled(.configDisabled, configured: false)),
            preparedModel: .init(snapshot: .init(model: model, eosTokenIds: eosTokenIds, extraEOSTokens: []),
                servingModel: model, assistant: nil,
                mtpStatus: .disabled(.configDisabled, configured: false), mtpArtifact: nil),
            environment: [PrefixCachePolicy.environmentFlag: "0", KVBackendGuardStore.pathEnvKey: "/dev/null",
                EngineV2KVQuantizationPolicy.environmentKey: "native"],
            startServingTelemetry: false, emitTelemetry: { _ in })
        return StandaloneServer.CachedSlot(bundle: bundle, container: container, tokenizer: tokenizerHandle,
            modelType: modelType, isVLM: false, sizing: sizing, lastUsedAt: .now)
    }
}

/// The calibration fixture's tokens, with each chat-template render taking `renderDelay` seconds.
private struct SlowTemplateTokenizer: Tokenizer {
    let renderDelay: Double
    private let tokens = ModelCalibrationTokenizer()
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { tokens.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokens.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] {
        Thread.sleep(forTimeInterval: renderDelay)
        return try tokens.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}

private struct CalibrationFixtureProcessor: UserInputProcessor {
    struct NotUsed: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw NotUsed() }
}

private extension EngineV2Bridge {
    func awaitProductionCalibration() async { await modelCalibration.task?.value }
    func shapeWarmupCompletedTest() -> Bool { modelCalibration.shapeWarmupWidth != nil }
    func shapeWarmupWidthTest() -> Int? { modelCalibration.shapeWarmupWidth }
    func setShapeWarmupCellsCompletedTest(_ cells: Int) { modelCalibration.shapeWarmupCellsCompleted = cells }
    func shapeWarmupCellsCompletedTest() -> Int { modelCalibration.shapeWarmupCellsCompleted }
    func setShapeWarmupModeTest(_ mode: ModelCalibrationPolicy.ShapeWarmupMode) {
        modelCalibration.shapeWarmupModeOverride = mode
    }
    func shaderCacheProbeTest() -> (cold: Bool?, runs: Int) {
        (modelCalibration.shaderCacheCold, modelCalibration.shaderCacheProbeRuns.count)
    }
    func scheduledShapeWarmupTest() -> Bool { modelCalibration.task != nil }
    func waitForPumpRetirement(requestId: String) async { await pumpTasks[requestId]?.value }
    func productionCalibrationWorkCounters() -> [Int64] {
        [prefillTokensTotal, prefillRequestsTotal, generatedTokensTotal, generationRequestsTotal]
    }
}

private extension StandaloneServer {
    func installShapeWarmupSlots(_ installed: [String: CachedSlot]) {
        lifecycleState = .running
        slots.merge(installed) { _, new in new }
    }
    func setDrainingForShapeWarmupTest() { lifecycleDraining = true }
    func removeShapeWarmupSlots() async {
        lifecycleState = .stopping
        for slot in slots.values { await slot.bridge.shutdown() }
        slots.removeAll()
        lifecycleDraining = false
        lifecycleState = .stopped
    }
}
