import CryptoKit
import Foundation
import MLX
@testable import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

@Suite("Checkpoint observation lifetime", .serialized)
struct ModelCheckpointObservationLifetimeTests {
    private final class Gate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var held = false

        func holdOnce() {
            guard lock.withLock({ if held { return false }; held = true; return true }) else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 10)
        }
    }

    /// Real tiny attention/cache work; only the optional scheduling gate is synthetic.
    private final class Model: CBv2SteppableModel, CBv2HistoricalAttentionCheckpointProviding,
                               CBv2CompleteCheckpointKVTypeProviding {
        let gate: Gate?
        let kinds = [CBv2LayerKind(attention: .full, headDim: 64, kvHeads: 1, queryHeads: 1)]
        var cbv2SupportsHistoricalAttentionCheckpoint: Bool { true }
        var cbv2CompleteCheckpointKVDTypes: [DType]? { [.float32] }

        init(gate: Gate? = nil) { self.gate = gate }

        func forward(tokens: MLXArray, caches: [CBv2AttendingLayerCache]) -> MLXArray {
            gate?.holdOnce()
            let batch = tokens.dim(0), length = tokens.dim(1)
            let kv = MLXArray.ones([batch, 1, length, 64], dtype: .float32)
            for cache in caches {
                _ = cache.updateAndAttend(queries: kv, keys: kv, values: kv, scale: 1, sinks: nil)
            }
            return broadcast(MLXArray([Float(0), 1]).reshaped([1, 1, 2]), to: [batch, length, 2])
        }
    }

    private func engine(_ model: Model, store: SSDHybridCheckpointStore? = nil,
                        stepTimeout: TimeInterval = 30) -> EngineV2 {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        return EngineV2(model: model, layerKinds: model.kinds,
            backend: CBv2ContiguousKVBackend(config: .init(bytesCapacity: 64 << 20, kvDType: .float32)),
            cacheProvider: CBv2LayerCacheBank(layerKinds: model.kinds), sampler: CBv2GreedySampler(),
            schedulerConfig: .init(maxConcurrentRequests: 1, maxBatchedTokensPerStep: 256,
                prefillChunkSize: 256, enablePrefixCache: store != nil),
            loopConfig: .init(stepTimeout: stepTimeout, watchdogInterval: 0.01, shutdownTimeout: 1),
            admissionConfig: .init(watermarkFraction: 0), completePrefixCache: store,
            completeCheckpointKVDTypes: model.cbv2CompleteCheckpointKVDTypes)
    }

    private func wait(_ semaphore: DispatchSemaphore, seconds: Double = 3) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + seconds) == .success)
            }
        }
    }

    @Test("watchdog failure and trace cleanup return while the real engine queue is stalled")
    func watchdogCleanupDoesNotJoinStalledQueue() async throws {
        let gate = Gate()
        let engine = engine(Model(gate: gate), stepTimeout: 0.05)
        let trace = try ModelCheckpointPrefillTrace(engine: engine)
        let capture = try trace.begin(requestID: .init(11), promptTokens: 3)
        let completed = DispatchSemaphore(value: 0)
        let collector = Task { () -> Bool in
            defer { completed.signal() }
            defer { trace.end(capture) }
            do {
                let stream = try engine.submit(.init(id: .init(11), promptTokens: [1, 1, 1], maxTokens: 8))
                var reason: CBv2FinishReason?
                var usage: CBv2Usage?
                var count = 0
                for await event in stream {
                    switch event {
                    case .delta(_, let tokens, _): count += tokens.count
                    case .finished(let finish, let value): reason = finish; usage = value
                    }
                }
                _ = try await ModelPrefixBenchmarkTerminal.completeSuccessfulRequest(
                    finish: reason, usage: usage, outputCount: count, expectedOutputCount: 8, complete: {})
                return false
            } catch { return !engine.isHealthy }
        }
        let entered = await wait(gate.entered)
        let failedBeforeRelease = await wait(completed)
        gate.release.signal()
        let rejected = await collector.value
        await engine.shutdown()
        #expect(entered && failedBeforeRelease && rejected,
            "failure propagation must not wait for the wedged queue to resume")
    }

    @Test("one installed observer owns isolated capture generations and does not overwrite another observer")
    func traceOwnershipAndReuse() async throws {
        let engine = engine(Model())
        do {
            let trace = try ModelCheckpointPrefillTrace(engine: engine)
            let first = try trace.begin(requestID: .init(11), promptTokens: 3)
            trace.end(first)
            let second = try trace.begin(requestID: .init(11), promptTokens: 3)
            trace.end(first) // Late cleanup must not deactivate the reused sampling ID.
            engine.loopForTesting.onEngineQueueSync {
                engine.loopForTesting.recurrentGeometryObserverForTesting?(.init(11), 0..<3, 3, false, "range", "")
            }
            #expect(trace.snapshot(first).isEmpty)
            #expect(trace.snapshot(second) == [.init(lowerBound: 0, upperBound: 3, plannedCap: 3, packed: false)])
            trace.end(second)
            #expect(throws: ModelCheckpointDonationControl.Failure.observerAlreadyInstalled) {
                try ModelCheckpointPrefillTrace(engine: engine)
            }
            // Rejecting a competing owner must leave the original callback intact.
            let third = try trace.begin(requestID: .init(11), promptTokens: 3)
            engine.loopForTesting.onEngineQueueSync {
                engine.loopForTesting.recurrentGeometryObserverForTesting?(.init(11), 0..<3, 3, false, "range", "")
            }
            #expect(trace.snapshot(third).count == 1)
            trace.end(third)
            await engine.shutdown()
        } catch {
            await engine.shutdown()
            throw error
        }
    }

    @Test("slow consumers retain real prefill residency evidence after COMPLETE SSD restore has retired")
    func bufferedRestoreKeepsPrefillMemory() async throws {
        let root = try SSDTestDirectory.parent().appendingPathComponent("prefill-memory-\(UUID().uuidString)")
        let modelRoot = root.appendingPathComponent("0123456789ab")
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SSDHybridCheckpointStore(config: .init(modelId: "prefill-memory-fixture",
            identity: .init(modelAggregateHash: "weights", promptContractID: "prompt", buildID: "build",
                numericsFingerprint: "native-f32"),
            backendLayout: CBv2CompleteCheckpointManifest.nativeContiguousHistoricalLayout,
            root: modelRoot, dedicatedRoot: root, epochStore: nil, maxReadBytes: 16 << 20,
            maxStageMillis: 1_000, minEffectiveTokens: 256, ttlSeconds: 1_800, strictFsync: false,
            nowSeconds: { Int64(Date().timeIntervalSince1970) }, diskBudgetBytes: { 1 << 30 }, maintainWholeRoot: {}),
            kekKey: SymmetricKey(size: .bits256), kvBudget: nil, maxWriteBytesPerDay: 1 << 30)
        store.scanOnDisk()
        let engine = engine(Model(), store: store)
        do {
            try #require(engine.completePrefixCache === store)
            var donor = CBv2Request(id: .init(11), promptTokens: Array(repeating: 1, count: 513),
                sampling: .init(temperature: 0), maxTokens: 8, cacheSalt: "tenant",
                prefixCacheReceiptID: .init(101), prefixCheckpointTargetTokens: 512)
            EngineV2BenchmarkSession.registerDonationDemand(for: donor, receiptID: .init(101), store: store)
            var expected: [Int] = []
            for await event in try engine.submit(donor) {
                if case .delta(_, let tokens, _) = event { expected += tokens }
            }
            await store.waitForWritesForTesting()
            store.completeStaging(requestID: .init(101))
            try #require(store.stats().filesWritten > 0)

            donor.id = .init(12)
            donor.prefixCacheReceiptID = .init(102)
            donor.prefixCheckpointTargetTokens = 0
            let memory = ModelPrefixBenchmarkPrefillMemoryCapture(requestID: donor.id)
            donor.onPrefillCompleted = { [weak engine] usage in
                if let engine { memory.record(usage: usage, engine: engine) }
            }
            let request = donor
            let stage = await store.stage(requestID: .init(102), request: request,
                reserveReadScratch: { try engine.reserveCompleteCheckpointReadScratch() },
                makeImportPlan: { try engine.planCompleteCheckpointImport(manifest: $0, request: request) })
            try #require(stage.disposition == .staged(matchedTokens: 512,
                expectedPrefillTokensSaved: 512, shortenedByCorruption: false))
            let stream = try engine.submit(request)
            // Leave all deltas buffered until the request and its actual backend retire.
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var retired = false
            while ContinuousClock.now < deadline {
                retired = engine.loopForTesting.onEngineQueueSync {
                    engine.stepCount > 0 && engine.loopForTesting.scheduler.runningCount == 0
                        && engine.loopForTesting.scheduler.waitingCount == 0
                        && engine.loopForTesting.backend.bytesInUse == 0
                }
                if retired, (try? memory.snapshot()) != nil { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(retired)
            var actual: [Int] = []
            var usage: CBv2Usage?
            for await event in stream {
                switch event {
                case .delta(_, let tokens, _): actual += tokens
                case .finished(_, let value): usage = value
                }
            }
            let observation = try memory.snapshot()
            #expect(observation.callbackCount == 1 && observation.backendBytesInUse > 0)
            #expect(observation.requestID == request.id.raw && observation.promptTokens == 513)
            #expect(observation.restoredTokens == 512 && usage?.prefixCachePrefillTokensSaved == 512)
            #expect(actual == expected && actual.count == 8)
            #expect(store.stats().filesRead > 0 && store.stats().stageConsumptions == 1)
            store.completeStaging(requestID: .init(102))
            await engine.shutdown()
            #expect(engine.capacity().kvBytesInUse == 0 && engine.capacity().kvBytesReserved == 0)
        } catch {
            await engine.shutdown()
            throw error
        }
    }
}
