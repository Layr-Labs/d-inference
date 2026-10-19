import CryptoKit
import Foundation
import MLX
import Testing
@testable import MLXLMCommon
@testable import ProviderCore

/// Exercises the actual EngineV2 native import binding and retirement queue
/// with tiny tensors; this is not a trained MiMo numerical qualification.
@Suite("Tracked native checkpoint retry authority", .serialized)
struct SSDTrackedNativeRetryTests {
    private final class Model: CBv2SteppableModel, CBv2HistoricalAttentionCheckpointProviding,
        CBv2CompleteCheckpointKVTypeProviding, CBv2NativeCompletePrefixBindingValidating {
        let scale = MLXArray(Float(1.0 / 32.0))
        var cbv2SupportsHistoricalAttentionCheckpoint: Bool { true }
        var cbv2CompleteCheckpointKVDTypes: [DType]? { [.float32] }
        func validateNativeCompletePrefixBinding() throws {}
        func forward(tokens: MLXArray, caches: [CBv2AttendingLayerCache]) -> MLXArray {
            let b = tokens.dim(0), n = tokens.dim(1)
            let hidden = tokens.asType(.float32).reshaped([b, 1, n, 1]) * scale
            let output = caches[0].updateAndAttend(
                queries: MLXArray.zeros([b, 2, n, 192]),
                keys: broadcast(hidden, to: [b, 1, n, 192]),
                values: broadcast(hidden, to: [b, 1, n, 128]), scale: 0.125, sinks: nil)
            return broadcast(mean(output, axes: [1, 3]).reshaped([b, n, 1]), to: [b, n, 32])
        }
    }

    private final class Gate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var armed = false
        private var held = false
        private var positions: [Int] = []
        func record(_ position: Int) { lock.withLock { positions.append(position) } }
        var attempts: [Int] { lock.withLock { positions } }
        func arm() { lock.withLock { armed = true } }
        func waitForEntry() async -> Bool {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: self.entered.wait(timeout: .now() + 5) == .success)
                }
            }
        }
        func hold() {
            guard lock.withLock({
                guard armed && !held else { return false }
                held = true
                return true
            }) else { return }
            entered.signal()
            _ = released.wait(timeout: .now() + 10)
        }
    }

    @Test("allocation refusal cannot rearm while the real native manifest is retiring")
    func delayedNativeRetirementStaysCold() async throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let root = try SSDTestDirectory.parent().appendingPathComponent("tracked-retry-\(UUID().uuidString)")
        let modelRoot = root.appendingPathComponent("0123456789ab")
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
        defer { try? FileManager.default.removeItem(at: root) }
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30) })
        let identity = CBv2CompleteCheckpointIdentity(modelAggregateHash: "tracked-weights",
            promptContractID: "tracked-contract", buildID: "tracked-build", numericsFingerprint: "tracked-numerics")
        let store = SSDHybridCheckpointStore(config: .init(modelId: "tracked-fixture", identity: identity,
            backendLayout: CBv2CompleteCheckpointManifest.contiguousAsymmetricLayout,
            root: modelRoot, dedicatedRoot: root, epochStore: nil, maxReadBytes: 16 << 20,
            maxStageMillis: 1000, minEffectiveTokens: 256, ttlSeconds: 3600, strictFsync: false,
            nowSeconds: { Int64(Date().timeIntervalSince1970) }, diskBudgetBytes: { 1 << 30 }, maintainWholeRoot: {}),
            kekKey: SymmetricKey(size: .bits256), kvBudget: budget, diskBudget: SSDDiskBudget(), maxWriteBytesPerDay: 1 << 30)
        store.scanOnDisk()
        let model = Model()
        let kinds: [CBv2LayerKind] = [.init(attention: .full, headDim: 192, valueHeadDim: 128, kvHeads: 1, queryHeads: 2)]
        let backend = CBv2ContiguousKVBackend(config: .init(bytesCapacity: 128 << 20, kvDType: .float32))
        let bank = CBv2LayerCacheBank(layerKinds: kinds)
        let owner = budget.makeEngineMemoryOwner()
        let scope = NativeConstructionScope()
        let engine = try scope.withPhase(.nativeSetup) {
            try scope.capture(StreamOrDevice.cpu.stream)
            try scope.capture(StreamOrDevice.default.stream)
            try scope.retain(model.scale)
            try scope.willSubmit()
            try withError { errors in eval(model.scale); try errors.check() }
            try scope.authorizeImmutableLoadedOwner(model)
            try scope.retainOwner(backend)
            try scope.retainOwner(bank)
            try scope.retainOwner(store)
            let contract = try CBv2NativeExecutionContract(model: model, backend: backend,
                cacheProvider: bank, assistant: nil, construction: scope, loadedOwner: model,
                completePrefixCache: store, completePrefixValidator: model, prefixProcessMemoryOwner: owner)
            let engine = MLXLMCommon.EngineV2(model: model, layerKinds: kinds, backend: backend,
                cacheProvider: bank, schedulerConfig: .init(maxConcurrentRequests: 2,
                    maxBatchedTokensPerStep: 256, prefillChunkSize: 256, enablePrefixCache: true),
                loopConfig: .init(stepTimeout: 60, watchdogInterval: 0.01, shutdownTimeout: 10),
                admissionConfig: .init(watermarkFraction: 0), completePrefixCache: store,
                processMemoryOwner: owner, nativeCompletionTracking: true, nativeExecutionContract: contract)
            try scope.retainOwner(engine)
            return engine
        }
        let codec = try #require(engine.completeCheckpointCodec)
        let tokens = (0..<513).map { $0 % 31 }
        let request = CBv2Request(id: .init(993), promptTokens: tokens, maxTokens: 8,
            cacheSalt: "tenant", prefixCacheReceiptID: .init(994))
        let gate = Gate()
        defer { gate.released.signal() }
        do {
            for position in [256, 512] {
                let manifest = CBv2CompleteCheckpointManifest(identity: identity, position: position,
                    chunkSize: 256, prefixTokens: Array(tokens.prefix(position)), cacheSalt: "tenant",
                    assistantCodecID: nil, tensors: try codec.tensorDescriptors(position: position),
                    backendLayout: codec.backendLayout, attentionLayers: codec.contiguousLayout?.layers)
                let arrays = manifest.tensors.map { MLXArray.zeros($0.shape, dtype: .float32) }
                eval(arrays)
                let source = CBv2CompleteCheckpointExport(manifest: manifest, arrays: arrays, usesProcessMemoryOwner: true)
                let donated: [Int] = await withCheckedContinuation { continuation in
                    store.donate(source, requestID: .init(UInt64(position)), tokens: tokens, cacheSalt: "tenant") {
                        continuation.resume(returning: $0)
                    }
                }
                try #require(donated == [position])
            }
            let tracking = try #require(engine.loopForTesting.nativeShutdownState)
            engine.loopForTesting.onEngineQueueSync { tracking.beforeFenceForTesting = { _ in gate.hold() } }
            let result = await store.stage(requestID: .init(994), request: request,
                reserveReadScratch: { .init(reservation: .init(onRelease: {}), usesProcessMemoryOwner: true) }) { manifest in
                    gate.record(manifest.position)
                    let plan = try engine.planCompleteCheckpointImport(manifest: manifest, request: request)
                    let admission = engine.admissionForTesting
                    let required = plan.nativeTargetBytes + plan.nativeAuxiliaryBytes + plan.checkpointHostBytes + plan.scratchBytes
                    let pressureBytes = admission.bytesCapacity - admission.bytesReserved - required + 1
                    let pressure = try admission.reserveTransient(bytes: pressureBytes)
                    plan.evaluateDestinations = { _ in
                        _ = withExtendedLifetime(pressure) { Issue.record("capacity refusal must precede native allocation") }
                    }
                    gate.arm()
                    return plan
                }
            #expect(await gate.waitForEntry())
            #expect(result.disposition == .skippedCapacity)
            #expect(gate.attempts == [512], "host refund is not a native retirement receipt")
            #expect(engine.admissionForTesting.bytesReserved > 0, "queued native owner still holds its charge")
            #expect(store.stats().entries == 2 && store.stats().corruptDropped == 0)
            gate.released.signal()
            engine.loopForTesting.onEngineQueueSync { tracking.beforeFenceForTesting = nil }
        } catch {
            gate.released.signal()
            _ = await engine.shutdownReportingNativeCompletion()
            await store.closeAndWait()
            throw error
        }
        let shutdown = await engine.shutdownReportingNativeCompletion()
        guard case .quiescent = shutdown else {
            _ = Unmanaged.passRetained(engine)
            Issue.record("native retirement failed to quiesce")
            return
        }
        await store.closeAndWait()
        #expect(engine.admissionForTesting.bytesReserved == 0)
    }
}
