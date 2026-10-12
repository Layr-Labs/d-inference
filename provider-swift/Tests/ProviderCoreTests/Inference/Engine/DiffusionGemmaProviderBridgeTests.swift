import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Testing

@testable import MLXVLM
@testable import ProviderCore

@Suite("Diffusion packed preflight and capacity", .serialized)
struct DiffusionGemmaProviderBridgeTests {
    private let modelID = "diffusion-bridge-fixture"
    private let capacity = 64 << 20

    private enum Failure: Error { case child, terminalTimeout }

    private func configuration(window: Int = 256, splitGeometry: Bool = false) throws
        -> DiffusionGemmaConfiguration
    {
        try JSONDecoder().decode(DiffusionGemmaConfiguration.self, from: JSONSerialization.data(
            withJSONObject: [
                "model_type": "diffusion_gemma", "canvas_length": 4,
                "text_config": [
                    "vocab_size": 128, "hidden_size": 32, "intermediate_size": 48,
                    "moe_intermediate_size": 16, "num_hidden_layers": 2,
                    "num_attention_heads": 4, "num_key_value_heads": 2,
                    "num_global_key_value_heads": splitGeometry ? 1 : 2,
                    "head_dim": 64, "global_head_dim": splitGeometry ? 128 : 64,
                    "sliding_window": window, "max_position_embeddings": 2048,
                    "num_experts": 4, "top_k_experts": 2,
                    "layer_types": ["sliding_attention", "full_attention"],
                ],
            ]))
    }

    private func container(_ configuration: DiffusionGemmaConfiguration, dtype: DType = .float32)
        throws -> DiffusionGemmaContainer
    {
        _ = try #require(LiveInferenceFixtures.ensureMetallibColocated())
        let model = DiffusionGemma(configuration)
        model.update(parameters: model.parameters().mapValues { $0.asType(dtype) })
        model.train(false)
        eval(model)
        return DiffusionGemmaContainer(context: DiffusionGemmaContext(
            configuration: .init(directory: FileManager.default.temporaryDirectory), model: model,
            generationConfiguration: try .init(maxNewTokens: 4, maxDenoisingSteps: 4, eosTokenIds: []),
            tokenizer: StubBridgeTokenizer(), chatTemplate: "unused", processor: nil))
    }

    private func budget() -> GlobalKVCacheBudget {
        GlobalKVCacheBudget(memorySnapshot: {
            .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
        })
    }

    private final class PreflightCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var captured: ([CBv2LayerKind], PagedKernelPreflight.Request)?
        var value: ([CBv2LayerKind], PagedKernelPreflight.Request)? { lock.withLock { captured } }
        func record(_ kinds: [CBv2LayerKind], _ request: PagedKernelPreflight.Request) {
            lock.withLock { captured = (kinds, request) }
        }
    }

    @Test(arguments: [EngineV2KVQuantizationSelection.balanced, .k8v4, .k8v8],
          [DType.float16, .bfloat16, .float32])
    func packedChildFailurePrecedesConstruction(
        selection: EngineV2KVQuantizationSelection, dtype: DType
    ) async throws {
        for window in [64, 512] {
            let configuration = try configuration(window: window, splitGeometry: true)
            let target = try container(configuration, dtype: dtype)
            let capture = PreflightCapture(), budget = budget()
            await #expect(throws: Failure.self) {
                // A skipped preflight instead reaches the invalid zero-capacity
                // engine. The injected child failure must own this outcome.
                _ = try await DiffusionGemmaProviderBridge.make(
                    container: target, modelID: modelID, kvBytesCapacity: 0,
                    sharedBudget: budget, pageBacked: true, kvQuantization: selection,
                    pagedPreflightOverride: { kinds in
                        try PagedKernelPreflight.run(
                            layerKinds: kinds, precision: selection, executableURL: nil,
                            childRunner: { request in
                                capture.record(kinds, request)
                                throw Failure.child
                            })
                    })
            }
            let (kinds, request) = try #require(capture.value)
            #expect(kinds == configuration.textConfig.diffusionPagedLayerKinds)
            #expect(request.precision == selection)
            #expect(request.nativeShapes.count == 2)
            #expect(request.packedShapes.count == (window == 64 ? 9 : 18))
            for queryType in [DType.float16, .bfloat16, .float32] {
                #expect(request.packedShapes.contains(.init(
                    headDim: 128, kvHeads: 1, queryHeads: 4, hasSinks: false,
                    dtype: dtype, queryDType: queryType)))
                let windowShape = PagedQuantizedKernelSmokeShape(
                    headDim: 64, kvHeads: 2, queryHeads: 4, hasSinks: false,
                    windowSize: window, dtype: dtype, queryDType: queryType)
                #expect(request.packedShapes.contains(windowShape) == (window > 128))
            }
            #expect(await budget.outstandingReservedBytes() == 0)
        }
    }

    private func bundle(
        selection: EngineV2KVQuantizationSelection = .native, backend: String = "auto",
        environment: [String: String] = [:],
        kvBytesCapacity: Int = 0,
        preflight: (([CBv2LayerKind]) throws -> Void)? = nil
    ) async throws -> ProviderEngineBundle {
        let configuration = try configuration()
        return try await EngineV2SlotFactory.makeProductionBundle(
            modelId: modelID, modelType: "diffusion_gemma", isVLM: false, modelDirectory: nil,
            container: .diffusion(try container(configuration)),
            tokenizer: TokenizerHandle(StubBridgeTokenizer()),
            sizing: .init(weightsBytes: 1, fp16KVBytesPerToken: 512,
                maxContextLength: 2048, defaultMaxTokens: 4),
            kvBytesCapacity: kvBytesCapacity, maxConcurrentRequests: 2, kvBudget: budget(),
            kvBackendConfig: backend, kvQuantizationConfig: selection.rawValue,
            specDecPreparation: .init(artifact: nil, status: .disabled(.targetUnsupported, configured: false)),
            assemblyOverrides: .init(pagedPreflight: preflight),
            environment: [PrefixCachePolicy.environmentFlag: "0",
                          PrefixCachePolicy.memoryEnvironmentFlag: "0"]
                .merging(environment) { _, override in override },
            startServingTelemetry: false)
    }

    @Test(arguments: [EngineV2KVQuantizationSelection.balanced, .k8v4, .k8v8], ["auto", "paged"])
    func productionFactoryForwardsPreflight(
        selection: EngineV2KVQuantizationSelection, backend: String
    ) async throws {
        await #expect(throws: Failure.self) {
            let bundle = try await bundle(selection: selection, backend: backend,
                preflight: { _ in throw Failure.child })
            await bundle.bridge.shutdown()
        }
    }

    @Test(arguments: [EngineV2KVQuantizationSelection.balanced, .k8v4, .k8v8], ["auto", "paged"])
    func killSwitchStillRefusesPackedBeforePreflight(
        selection: EngineV2KVQuantizationSelection, backend: String
    ) async throws {
        await #expect(throws: EngineV2KVQuantizationPolicy.Failure.self) {
            let bundle = try await bundle(selection: selection, backend: backend,
                environment: [EngineV2KVBackendPolicy.killSwitchEnvKey: "0"],
                preflight: { _ in Issue.record("Disabled paging reached kernel preflight") })
            await bundle.bridge.shutdown()
        }
    }

    @Test(arguments: ["auto", "contiguous", "paged"], [false, true])
    func nativeFactoryReportsOnlyActualKillSwitchFallback(backend: String, killed: Bool) async throws {
        let bundle = try await bundle(backend: backend,
            environment: killed ? [EngineV2KVBackendPolicy.killSwitchEnvKey: "0"] : [:],
            kvBytesCapacity: capacity,
            preflight: { _ in Issue.record("Native precision reached packed kernel preflight") })
        let bridge = bundle.bridge
        let expectedPaged = backend == "paged" && !killed
        let expectedReason = backend == "paged" && killed ? "kill_switch" : nil
        let engine = try #require(await bridge.ownedEngine as? CBv2NativeBlockEngine)
        #expect(engine.usesPagedStorage == expectedPaged)
        #expect(await bridge.kvBackendKind == (expectedPaged ? .paged : .contiguous))
        #expect(await bridge.kvBackendFallbackReason == expectedReason)
        #expect(bridge.kvQuantization == .native)
        let slot = await bridge.backendSlotCapacity()
        let diagnostic = bridge.slotPosture(await bridge.mtpStatusSnapshot())
        #expect(slot.kvBackend == (expectedPaged ? "paged" : "contiguous"))
        #expect(slot.kvBackendFallbackReason == expectedReason)
        #expect(diagnostic.kvBackend == slot.kvBackend)
        #expect(diagnostic.kvBackendFallbackReason == expectedReason)
        await bridge.shutdown()
    }

    @Test(arguments: [false, true])
    func nativePathsKeepTheirBudgetAndSkipPackedPreflight(pageBacked: Bool) async throws {
        let prepared = try await DiffusionGemmaProviderBridge.make(
            container: try container(configuration()), modelID: modelID,
            kvBytesCapacity: capacity, maxConcurrentRequests: 2,
            sharedBudget: pageBacked ? budget() : nil, pageBacked: pageBacked,
            pagedPreflightOverride: { _ in throw Failure.child })
        let engine = try #require(await prepared.bridge.ownedEngine as? CBv2NativeBlockEngine)
        #expect(engine.usesPagedStorage == pageBacked)
        #expect(engine.maximumNativeRecentFeasibilityBytes == 0)
        #expect(await prepared.bridge.fixedRequestBytes == 0)
        #expect(prepared.bridge.kvQuantization == .native)
        let slot = await prepared.bridge.backendSlotCapacity()
        #expect(slot.kvBytesPerToken == 1024)
        #expect(slot.activeTokenBudgetUsed == 0)
        #expect(slot.activeTokenBudgetMax == Int64(capacity / 1024))
        await prepared.bridge.shutdown()
    }

    #if DEBUG
    private final class TerminalGate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var terminal: CBv2Usage?
        var usage: CBv2Usage? { lock.withLock { terminal } }
        func enter(_ value: CBv2Usage) async {
            await withCheckedContinuation { continuation in
                let resume = lock.withLock {
                    terminal = value
                    if opened { return true }
                    waiter = continuation
                    return false
                }
                if resume { continuation.resume() }
            }
        }
        func open() {
            let parked = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                opened = true
                let value = waiter
                waiter = nil
                return value
            }
            parked?.resume()
        }
    }

    private func terminal(_ gate: TerminalGate) async throws -> CBv2Usage {
        let deadline = ContinuousClock.now + .seconds(30)
        while gate.usage == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        guard let usage = gate.usage else { throw Failure.terminalTimeout }
        return usage
    }

    private func drain(_ stream: AsyncStream<GenerationEvent>) async -> [String] {
        var errors: [String] = []
        for await event in stream {
            if case .error(let message) = event { errors.append(message) }
        }
        return errors
    }

    @Test(arguments: EngineV2KVQuantizationSelection.allCases)
    func realHeartbeatChargesActiveAndProspectiveBandsOnce(
        selection: EngineV2KVQuantizationSelection
    ) async throws {
        let budget = budget()
        let prepared = try await DiffusionGemmaProviderBridge.make(
            container: try container(configuration()), modelID: modelID,
            kvBytesCapacity: capacity, maxConcurrentRequests: 3, sharedBudget: budget,
            retainMemoryPrefixes: false, prefillChunkSize: 32,
            pageBacked: true, kvQuantization: selection)
        let bridge = prepared.bridge
        let engine = try #require(await bridge.ownedEngine as? CBv2NativeBlockEngine)
        let fixed = engine.maximumNativeRecentFeasibilityBytes
        let rate = await bridge.kvBytesPerToken
        let firstGate = TerminalGate(), secondGate = TerminalGate()
        defer { firstGate.open(); secondGate.open() }
        do {
            #expect((fixed > 0) == (selection != .native))
            #expect(fixed * 3 < capacity)
            #expect(await bridge.fixedRequestBytes == fixed)
            #expect(await bridge.requestReservationBytes(tokenCount: 0) == fixed)
            #expect(await bridge.requestReservationBytes(tokenCount: -1) == nil)
            #expect(await bridge.requestReservationBytes(tokenCount: Int.max) == nil)
            let idle = await bridge.backendSlotCapacity()
            #expect(idle.activeTokenBudgetUsed == 0)
            #expect(idle.activeTokenBudgetMax == Int64((capacity - 3 * fixed) / rate))

            let request = ChatCompletionRequest(model: modelID, messages: [], temperature: 0, max_tokens: 4)
            await bridge._testInstallCancelledSettlementHooks(
                beforeNativeTerminal: { await firstGate.enter($0) }, onSettlementWait: {})
            let first = await bridge.submitTokenized(promptTokens: Array(repeating: 3, count: 7),
                request: request, requestId: "short", cacheEnabled: false)
            let firstUsage = try await terminal(firstGate)
            #expect(firstUsage.promptTokens == 7 && firstUsage.completionTokens == 4)
            let one = await bridge.backendSlotCapacity()
            #expect(one.maxTokensPotential == 11)
            #expect(one.activeTokenBudgetUsed == Int64((11 * rate + fixed + rate - 1) / rate))
            #expect(one.activeTokenBudgetMax == Int64((capacity - 2 * fixed) / rate))

            await bridge._testInstallCancelledSettlementHooks(
                beforeNativeTerminal: { await secondGate.enter($0) }, onSettlementWait: {})
            let second = await bridge.submitTokenized(promptTokens: Array(repeating: 3, count: 257),
                request: request, requestId: "long", cacheEnabled: false)
            let secondUsage = try await terminal(secondGate)
            #expect(secondUsage.promptTokens == 257 && secondUsage.completionTokens == 4)
            #expect(engine.capacity().stepsExecuted > 0)
            #expect(await bridge.requestReservationBytes(tokenCount: 11) == 11 * rate + fixed)
            #expect(await bridge.requestReservationBytes(tokenCount: 261) == 261 * rate + fixed)
            let committed = 272 * rate + 2 * fixed
            for clamp in [-1, 0, fixed - 1, fixed, capacity, Int.max] {
                let slot = await bridge.backendSlotCapacity(kvBytesBudgetClamp: clamp)
                #expect(slot.maxTokensPotential == 272)
                #expect(slot.activeTokenBudgetUsed == Int64((committed + rate - 1) / rate))
                #expect(slot.activeTokenBudgetMax == Int64(max(0, min(capacity, max(0, clamp)) - fixed) / rate))
            }
            firstGate.open()
            secondGate.open()
            #expect(await drain(first).isEmpty)
            #expect(await drain(second).isEmpty)
            let retired = await bridge.backendSlotCapacity()
            #expect(retired.activeTokenBudgetUsed == 0)
            #expect(retired.activeTokenBudgetMax == idle.activeTokenBudgetMax)
            #expect(engine.maximumNativeRecentFeasibilityBytes == fixed)
            await bridge.shutdown()
            #expect(engine.capacity().kvBytesReserved == 0)
            #expect(await budget.outstandingReservedBytes() == 0)
        } catch {
            firstGate.open()
            secondGate.open()
            await bridge.shutdown()
            throw error
        }
    }
    #endif
}
