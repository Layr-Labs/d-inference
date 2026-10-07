import Foundation
import MLX
import Testing
@testable import MLXLMCommon
@testable import ProviderCore

@Suite("Ordinary EngineV2 fixed-workspace concurrency", .serialized)
struct EngineV2MemoryConcurrencyTests {
    private let gib = 1 << 30
    // Qwen-like reservation geometry only; the fixture never allocates this workspace.
    private let workspace = 619_000_000
    private let rate = 8

    private func fixture(
        grant: Int, configured: Int = 4, fixedBytes: Int = 619_000_000,
        watermark: Double = 0.05, auxiliaryBytes: Int = 0,
        auxiliaryGranularity: Int = 1,
        model: MemoryConcurrencyModel = MemoryConcurrencyModel(),
        backend: (any CBv2KVBackend)? = nil,
        budget: GlobalKVCacheBudget? = nil
    ) -> (engine: EngineV2, bridge: EngineV2Bridge) {
        let engine = EngineV2(
            model: model, layerKinds: model.kinds,
            backend: backend ?? CBv2ContiguousKVBackend(config: .init(bytesCapacity: grant)),
            cacheProvider: CBv2LayerCacheBank(layerKinds: model.kinds),
            sampler: CBv2GreedySampler(),
            schedulerConfig: .init(
                maxConcurrentRequests: max(1, configured), maxBatchedTokensPerStep: 8,
                prefillChunkSize: 8, maxWaiting: 8, enablePrefixCache: false),
            admissionConfig: .init(watermarkFraction: watermark,
                elementBytes: 4, fixedBytesPerRequest: fixedBytes))
        let bridge = EngineV2Bridge(
            engine: engine, modelId: "ordinary-fixed-workspace",
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [],
            maxConcurrentRequests: configured, kvBytesPerToken: rate + auxiliaryBytes,
            fixedRequestBytes: engine.resolvedFixedBytesPerRequest,
            auxiliaryBytesPerToken: auxiliaryBytes,
            auxiliaryTokenGranularity: auxiliaryGranularity, kvBudget: budget)
        return (engine, bridge)
    }

    @Test("2 GiB serves one ordinary request instead of reserving four or eight workspaces")
    func ordinaryIdleSlotRetainsUsableKV() async {
        for configured in [4, 8] {
            let (engine, bridge) = fixture(grant: 2 * gib, configured: configured)
            #expect(engine.nativeShutdownExecutionContractID == nil)
            #expect(await !bridge.tracksNativeShutdown)
            #expect(engine.resolvedFixedBytesPerRequest == workspace)
            #expect(configured * workspace > engine.capacity().kvBytesCapacity)

            let slot = await bridge.backendSlotCapacity()
            #expect(slot.state == "idle")
            #expect(slot.maxConcurrency == 1)
            #expect(await bridge.effectiveServingConcurrency(allowExpansion: true) == 1)
            #expect(slot.activeTokenBudgetMax == Int64(
                (engine.admissibleKVBytesCapacity - workspace) / rate))
            #expect(slot.activeTokenBudgetMax * Int64(rate) >= Int64(gib))
            #expect(slot.activeTokenBudgetUsed == 0)
            let stream = await bridge.submitTokenized(promptTokens: [1, 1],
                request: .init(model: "ordinary-fixed-workspace", messages: [], max_tokens: 1),
                requestId: "first-at-reduced-width", cacheEnabled: false)
            #expect(await errors(in: stream).isEmpty)
            #expect(await bridge._testCounters().admits == 1)
            #expect(await bridge._testCounters().firstTokens == 1)
            #expect(await bridge.activeRequestCount() == 0)
            #expect(await bridge.backendSlotCapacity().activeTokenBudgetUsed == 0)
            await bridge.shutdown()
        }
    }

    @Test("grant shrink, exact minimum-KV boundary, and recovery use the same live ceiling")
    func liveGrantCycleAndMinimumBoundary() async {
        let (engine, bridge) = fixture(grant: 8 * gib, configured: 8, watermark: 0)
        for (grant, expected) in [
            (8 * gib, 8), (2 * gib, 1), (gib + workspace - 1, 0),
            (gib + workspace, 1), (gib, 0), (0, 0), (-1, 0), (8 * gib, 8),
        ] {
            await bridge.updateKVBytesCapacity(grant)
            let slot = await bridge.backendSlotCapacity()
            #expect(engine.capacity().kvBytesCapacity == max(0, grant))
            #expect(engine.capacity().kvBytesBackendCapacity == max(0, grant))
            #expect(slot.maxConcurrency == UInt32(expected))
            #expect(await bridge.effectiveServingConcurrency(allowExpansion: true) == expected)
            let allowed = await bridge.acquireServiceAllowance(requestID: "probe")
            #expect(allowed == (expected > 0))
            await bridge.releaseServiceAllowance(requestID: "probe")
            if expected > 0 {
                #expect(slot.activeTokenBudgetMax == Int64((grant - expected * workspace) / rate))
                #expect(slot.activeTokenBudgetMax * Int64(rate) >= Int64(gib))
            } else {
                #expect(slot.activeTokenBudgetMax == 0)
            }
        }
        await bridge.shutdown()
    }

    @Test("ordinary concurrency honors the real watermark, fixed backend, and live fleet clamp")
    func admissionAndBackendCeilingsRemainAuthoritative() async {
        let (engine, bridge) = fixture(grant: 4 * gib, watermark: 0.25)
        #expect(engine.admissibleKVBytesCapacity == 3 * gib)
        let slot = await bridge.backendSlotCapacity()
        #expect(slot.maxConcurrency == 3)
        #expect(slot.activeTokenBudgetMax == Int64((3 * gib - 3 * workspace) / rate))
        let clamped = await bridge.backendSlotCapacity(kvBytesBudgetClamp: 2 * gib)
        #expect(clamped.maxConcurrency == 1)
        #expect(clamped.activeTokenBudgetMax == Int64((2 * gib - workspace) / rate))
        let raised = await bridge.backendSlotCapacity(kvBytesBudgetClamp: 8 * gib)
        #expect(raised.maxConcurrency == slot.maxConcurrency)
        #expect(raised.activeTokenBudgetMax == slot.activeTokenBudgetMax)
        #expect(await bridge.backendSlotCapacity(kvBytesBudgetClamp: -1).activeTokenBudgetMax == 0)
        await bridge.shutdown()

        // A real EngineV2 ledger may grow while its backend cannot. No pool bytes
        // or model weights are allocated by this capacity-only backend fixture.
        let (fixedEngine, fixedBridge) = fixture(grant: 2 * gib,
            backend: MemoryConcurrencyFixedBackend(bytesCapacity: 2 * gib))
        await fixedBridge.updateKVBytesCapacity(8 * gib)
        #expect(fixedEngine.capacity().kvBytesCapacity == 8 * gib)
        #expect(fixedEngine.capacity().kvBytesBackendCapacity == 2 * gib)
        let fixed = await fixedBridge.backendSlotCapacity()
        #expect(fixed.maxConcurrency == 1)
        #expect(await fixedBridge.effectiveServingConcurrency(allowExpansion: true) == 1)
        #expect(fixed.activeTokenBudgetMax == Int64((2 * gib - workspace) / rate))
        await fixedBridge.shutdown()
    }

    @Test("shrinking below accepted work keeps every commitment and refuses new work until recovery")
    func activeCommitmentsSurviveGrantShrink() async {
        let model = MemoryConcurrencyModel(holdFirstForward: true)
        defer { model.release() }
        let budget = GlobalKVCacheBudget(memorySnapshot: {
            .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
        })
        let (engine, bridge) = fixture(grant: 4 * gib, model: model, budget: budget)
        let request = ChatCompletionRequest(model: "ordinary-fixed-workspace", messages: [], max_tokens: 1)
        let first = await bridge.submitTokenized(promptTokens: [1, 1], request: request,
            requestId: "active-first", cacheEnabled: false)
        let deadline = ContinuousClock.now + .seconds(10)
        while !model.forwardEntered, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(model.forwardEntered)
        let second = await bridge.submitTokenized(promptTokens: [1, 1], request: request,
            requestId: "active-second", cacheEnabled: false)
        #expect(await bridge.activeRequestCount() == 2)
        let committed = 2 * (workspace + 3 * rate)
        #expect(await budget.outstandingReservedBytes() == UInt64(committed))
        let reserved = engine.admissionForTesting.bytesReserved
        #expect(reserved >= workspace)

        for (grant, expected) in [(2 * gib, 1), (0, 0)] {
            await bridge.updateKVBytesCapacity(grant)
            let slot = await bridge.backendSlotCapacity()
            #expect(slot.maxConcurrency == UInt32(expected))
            #expect(slot.maxTokensPotential == 6)
            #expect(slot.activeTokenBudgetUsed == Int64(committed / rate))
            #expect(await budget.outstandingReservedBytes() == UInt64(committed))
            #expect(engine.admissionForTesting.bytesReserved == reserved)
            let allowed = await bridge.acquireServiceAllowance(requestID: "after-shrink")
            #expect(!allowed)
            await bridge.releaseServiceAllowance(requestID: "after-shrink")
            #expect(await bridge.activeRequestCount() == 2)
        }

        await bridge.updateKVBytesCapacity(4 * gib)
        let recovered = await bridge.backendSlotCapacity()
        #expect(recovered.maxConcurrency == 4)
        #expect(recovered.activeTokenBudgetUsed == Int64(committed / rate))
        #expect(recovered.activeTokenBudgetMax == Int64(
            (engine.admissibleKVBytesCapacity - 2 * workspace) / rate))
        #expect(await bridge.acquireServiceAllowance(requestID: "after-growth"))
        await bridge.releaseServiceAllowance(requestID: "after-growth")
        model.release()
        #expect(await errors(in: first).isEmpty)
        #expect(await errors(in: second).isEmpty)
        await bridge.shutdown()
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(budget.serviceBudget.count == 0)
        #expect(engine.admissionForTesting.bytesReserved == 0)
    }

    @Test("pending submissions consume the reduced width across actor suspension and cancellation")
    func suspendedSubmissionCannotOverbookWorkspace() async {
        let (_, bridge) = fixture(grant: 2 * gib)
        let gate = UpgradeBarrier()
        await bridge._testInstallPreSubmitGate { await gate.wait() }
        // Zero-output work completes without a forward once the gate is released.
        let request = ChatCompletionRequest(model: "ordinary-fixed-workspace", messages: [], max_tokens: 0)
        let pending = Task {
            await bridge.submitTokenized(promptTokens: [1], request: request,
                requestId: "pending", cacheEnabled: false)
        }
        await gate.observeEntry()
        #expect(await bridge._testPendingSubmissionCount() == 1)
        let refused = await bridge.submitTokenized(promptTokens: [1], request: request,
            requestId: "overbooked", cacheEnabled: false)
        #expect(await errors(in: refused) == [
            "token_budget_exhausted: whole-Mac service allowance exhausted",
        ])

        await bridge.updateKVBytesCapacity(4 * gib)
        let admitted = await bridge.submitTokenized(promptTokens: [1], request: request,
            requestId: "after-growth", cacheEnabled: false)
        #expect(await errors(in: admitted).isEmpty)
        #expect(await bridge._testPendingSubmissionCount() == 1)
        await bridge.updateKVBytesCapacity(2 * gib)
        #expect(await !bridge.acquireServiceAllowance(requestID: "still-pending"))
        await bridge.releaseServiceAllowance(requestID: "still-pending")
        await bridge.cancel(requestId: "pending")
        await gate.release()
        _ = await errors(in: pending.value)
        #expect(await bridge._testPendingSubmissionCount() == 0)
        #expect(await bridge.acquireServiceAllowance(requestID: "after-cancel"))
        await bridge.releaseServiceAllowance(requestID: "after-cancel")
        #expect(await bridge.backendSlotCapacity().activeTokenBudgetUsed == 0)
        await bridge.shutdown()
    }

    @Test("unrepresentable overhead and disabled concurrency fail closed without integer traps")
    func overflowAndZeroConcurrency() async {
        for auxiliaryBytes in [0, 1] {
            let (_, bridge) = fixture(grant: 8 * gib, fixedBytes: Int.max,
                auxiliaryBytes: auxiliaryBytes, auxiliaryGranularity: 2)
            if auxiliaryBytes > 0 {
                #expect(await bridge.maximumRequestOverheadBytes() == nil)
            }
            #expect(await bridge.effectiveServingConcurrency(allowExpansion: true) == 0)
            let slot = await bridge.backendSlotCapacity()
            #expect(slot.maxConcurrency == 0)
            #expect(slot.activeTokenBudgetMax == 0)
            #expect(await !bridge.acquireServiceAllowance(requestID: "overflow"))
            await bridge.releaseServiceAllowance(requestID: "overflow")
            await bridge.shutdown()
        }
        let (_, bridge) = fixture(grant: 8 * gib, configured: 0)
        #expect(await bridge.effectiveServingConcurrency(allowExpansion: true) == 0)
        #expect(await bridge.backendSlotCapacity().maxConcurrency == 0)
        #expect(await !bridge.acquireServiceAllowance(requestID: "disabled"))
        await bridge.releaseServiceAllowance(requestID: "disabled")
        await bridge.shutdown()
    }

    @Test("zero-overhead ordinary engines retain their existing width and token reporting")
    func statelessOrdinaryBehaviorIsUnchanged() async {
        let (_, bridge) = fixture(grant: 8 * gib, configured: 8, fixedBytes: 0)
        for grant in [8 * gib, 2 * gib, gib - 1, 1, 0] {
            await bridge.updateKVBytesCapacity(grant)
            #expect(await bridge.maximumRequestOverheadBytes() == 0)
            #expect(await bridge.effectiveServingConcurrency(allowExpansion: true) == 8)
            let slot = await bridge.backendSlotCapacity()
            #expect(slot.maxConcurrency == 8)
            #expect(slot.activeTokenBudgetMax == Int64(grant / rate))
            #expect(await bridge.acquireServiceAllowance(requestID: "stateless"))
            await bridge.releaseServiceAllowance(requestID: "stateless")
        }
        await bridge.shutdown()
    }

    private func errors(in stream: AsyncStream<GenerationEvent>) async -> [String] {
        var errors: [String] = []
        for await event in stream {
            if case .error(let message) = event { errors.append(message) }
        }
        return errors
    }
}

private final class MemoryConcurrencyModel: CBv2SteppableModel {
    private let model = DeadlineAdmissionFixtureModel()
    var kinds: [CBv2LayerKind] { model.kinds }
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var holdFirstForward: Bool
    private var entered = false

    init(holdFirstForward: Bool = false) { self.holdFirstForward = holdFirstForward }

    var forwardEntered: Bool { lock.withLock { entered } }
    func release() { gate.signal() }

    func forward(tokens: MLXArray, caches: [CBv2AttendingLayerCache]) -> MLXArray {
        let hold = lock.withLock {
            entered = true
            defer { holdFirstForward = false }
            return holdFirstForward
        }
        if hold { _ = gate.wait(timeout: .now() + 30) }
        return model.forward(tokens: tokens, caches: caches)
    }
}

private final class MemoryConcurrencyFixedBackend: CBv2KVBackend {
    let bytesCapacity: Int
    var bytesInUse: Int { 0 }
    init(bytesCapacity: Int) { self.bytesCapacity = bytesCapacity }

    func makeSequenceState(layerKinds: [CBv2LayerKind], promptLength: Int, maxLength: Int)
        throws -> [CBv2SequenceKV?] {
        preconditionFailure("capacity-only fixture must not submit requests")
    }

    func release(_ state: [CBv2SequenceKV?]) {}
}
