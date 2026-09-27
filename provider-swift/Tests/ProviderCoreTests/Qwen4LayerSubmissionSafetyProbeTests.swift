import Foundation
import MLX
import XCTest
@testable import MLXLLM
@testable import MLXLMCommon

/// Opt-in private safety probe. No real model, serving policy or other worker.
final class Qwen4LayerSubmissionSafetyProbeTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DARKBLOOM_QWEN4_LAYER_SAFETY_PROBE"] == "1"
            && ProcessInfo.processInfo.environment["DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST"] == "1")
    }

    private func backend() throws -> PagedKVBackend {
        let kinds = (0..<2).map { _ in CBv2LayerKind(
            attention: .full, headDim: 64, kvHeads: 1, queryHeads: 2) }
        return try PagedKVBackend(layerKinds: kinds, config: .init(
            capacityBytes: 8 << 20, maxPrefillChunk: 16, nominalMaxSequenceLength: 64,
            segmentSizeBytes: 32768, layerDTypes: [.bfloat16, .bfloat16]))
    }

    private func bound(_ backend: PagedKVBackend) throws -> ([PagedLayerCache], [CBv2SequenceKV?]) {
        let rows = try backend.makeSequenceState(layerKinds: backend.layerKinds, promptLength: 0, maxLength: 32)
        let caches = backend.makeLayerCaches()
        for (cache, row) in zip(caches, rows) { cache.setRows([try XCTUnwrap(row)]) }
        return (caches, rows)
    }

    func testPolicyIsClosedAndRequiresBoundNativeCaches() throws {
        let backend = try backend()
        let (caches, rows) = try bound(backend)
        defer { for cache in caches { cache.setRows([]) }; backend.release(rows) }
        for flag in ["", "0", "false", "true", "yes"] {
            XCTAssertNil(Qwen4ExpLayerSubmission.plan(batchSize: 1, sequenceWidth: 1,
                hasEmbeddings: false, hasPositions: false, caches: caches,
                environment: [Qwen4ExpLayerSubmission.flag: flag]))
        }
        for width in 1...6 {
            XCTAssertNotNil(Qwen4ExpLayerSubmission.plan(batchSize: 1, sequenceWidth: width,
                hasEmbeddings: false, hasPositions: false, caches: caches,
                environment: [Qwen4ExpLayerSubmission.flag: "1"]))
        }
        for (batch, width, embeddings, positions) in [(0, 1, false, false), (2, 1, false, false),
            (1, 0, false, false), (1, 7, false, false), (1, 64, false, false),
            (1, 1, true, false), (1, 1, false, true)] {
            XCTAssertNil(Qwen4ExpLayerSubmission.plan(batchSize: batch, sequenceWidth: width,
                hasEmbeddings: embeddings, hasPositions: positions, caches: caches,
                environment: [Qwen4ExpLayerSubmission.flag: "1"]))
        }
        let unknown = CBv2LayerCache(layerIndex: 0, kind: backend.layerKinds[0])
        XCTAssertNil(Qwen4ExpLayerSubmission.plan(batchSize: 1, sequenceWidth: 1,
            hasEmbeddings: false, hasPositions: false, caches: [unknown],
            environment: [Qwen4ExpLayerSubmission.flag: "1"]))
        caches[0].setRows([])
        XCTAssertNil(Qwen4ExpLayerSubmission.plan(batchSize: 1, sequenceWidth: 1,
            hasEmbeddings: false, hasPositions: false, caches: caches,
            environment: [Qwen4ExpLayerSubmission.flag: "1"]))
    }

    func testDeferredHostInputsAreFilledBeforeSubmissionAndScopeRemainsOpen() throws {
        let backend = try backend()
        let (caches, rows) = try bound(backend)
        defer { Stream.gpu.synchronize(); for cache in caches { cache.setRows([]) }; backend.release(rows) }
        let plan = try XCTUnwrap(Qwen4ExpLayerSubmission.plan(batchSize: 1, sequenceWidth: 1,
            hasEmbeddings: false, hasPositions: false, caches: caches,
            environment: [Qwen4ExpLayerSubmission.flag: "1"]))
        let slot = MLXArray.zeros([1, 1, 4], dtype: .float32)
        eval(slot)
        let view = slot.asData(access: .noCopy)
        let scope = CBv2DeferredHostFill.open()
        defer { scope.close(); scope.run() }
        var fills = 0
        scope.register {
            XCTAssertNil(CBv2DeferredHostFill.current)
            view.data.withUnsafeBytes { raw in
                let pointer = UnsafeMutableRawPointer(mutating: raw.baseAddress!).assumingMemoryBound(to: Float.self)
                for index in 0..<4 { pointer[index] = 7 }
            }
            fills += 1
        }
        let output = slot + Float(2)
        let before = Qwen4ExpLayerSubmissionInvocation.snapshot()
        XCTAssertTrue(plan.submit(output))
        XCTAssertEqual(fills, 1)
        XCTAssertTrue(CBv2DeferredHostFill.current === scope)
        eval(output)
        XCTAssertEqual(output.asArray(Float.self), [9, 9, 9, 9])
        scope.register { fills += 1 }
        XCTAssertTrue(plan.submit(output + Float(1)))
        XCTAssertEqual(fills, 2)
        XCTAssertEqual(Qwen4ExpLayerSubmissionInvocation.snapshot() - before, 2)
        scope.close(); scope.run()
        XCTAssertEqual(fills, 2)
    }

    func testExistingAndDeferredLateFaultsPreventSubmission() throws {
        let backend = try backend()
        let (caches, rows) = try bound(backend)
        defer {
            Stream.gpu.synchronize(); Stream.cpu.synchronize()
            for cache in caches { cache.setRows([]) }; backend.release(rows)
            backend.pool.writeValidation.clearAfterRetirement()
        }
        let plan = try XCTUnwrap(Qwen4ExpLayerSubmission.plan(batchSize: 1, sequenceWidth: 1,
            hasEmbeddings: false, hasPositions: false, caches: caches,
            environment: [Qwen4ExpLayerSubmission.flag: "1"]))
        let hidden = MLXArray.ones([1, 1, 4])
        let native = MLXArray.ones([1, 1, 1, 64], dtype: .bfloat16)
        let wrong = native.asType(.float32)
        let scope = CBv2DeferredHostFill.open()
        defer { scope.close(); scope.run() }
        scope.register {
            XCTAssertFalse(backend.pool.writeValidation.validate(
                keys: native, values: wrong, expected: .bfloat16, layerIndex: 1))
        }
        let before = Qwen4ExpLayerSubmissionInvocation.snapshot()
        XCTAssertFalse(plan.submit(hidden), "A deferred callback may reveal a late fault")
        XCTAssertFalse(plan.submit(hidden), "An already faulted bank stays closed")
        XCTAssertEqual(Qwen4ExpLayerSubmissionInvocation.snapshot(), before)
        XCTAssertNil(Qwen4ExpLayerSubmission.plan(batchSize: 1, sequenceWidth: 1,
            hasEmbeddings: false, hasPositions: false, caches: caches,
            environment: [Qwen4ExpLayerSubmission.flag: "1"]))
        XCTAssertTrue(CBv2DeferredHostFill.current === scope)
    }

    func testPartiallySubmittedLayerFaultRetiresAndSameIDRecovers() async throws {
        for failOnCall in [1, 3] {
            let backend = try backend()
            let model = LayerSubmissionFaultModel(failOnCall: failOnCall)
            let engine = EngineV2(model: model, layerKinds: backend.layerKinds, backend: backend,
                cacheProvider: CBv2LayerCacheBank(caches: backend.makeLayerCaches()),
                sampler: CBv2GreedySampler(), schedulerConfig: .init(maxConcurrentRequests: 1,
                    maxBatchedTokensPerStep: 16, prefillChunkSize: 16),
                admissionConfig: .init(watermarkFraction: 0))
            let before = Qwen4ExpLayerSubmissionInvocation.snapshot()
            var finish: CBv2FinishReason?
            for await event in try engine.submit(.init(id: .init(77), promptTokens: [1, 2, 3, 4, 5],
                sampling: .init(temperature: 0), maxTokens: 8)) {
                if case .finished(let reason, _) = event { finish = reason }
            }
            guard case .some(.error(let message)) = finish else {
                await engine.shutdown(); XCTFail("Late fault was not returned as a request error"); return
            }
            XCTAssertTrue(message.contains("paged KV dtype mismatch"))
            XCTAssertGreaterThan(Qwen4ExpLayerSubmissionInvocation.snapshot(), before,
                "The valid preceding layer must actually have been submitted")
            engine.loopForTesting.onEngineQueueSync {
                XCTAssertEqual(backend.bytesReserved, 0); XCTAssertEqual(backend.bytesWired, 0)
                XCTAssertEqual(engine.admissionForTesting.bytesReserved, 0)
                XCTAssertFalse(backend.pool.writeValidation.isFaulted)
            }
            model.allowValidCalls()
            var outputCount = 0
            for await event in try engine.submit(.init(id: .init(77), promptTokens: [2, 3],
                sampling: .init(temperature: 0), maxTokens: 2)) {
                switch event {
                case .delta(_, let tokens, _): outputCount += tokens.count
                case .finished(let reason, _): finish = reason
                }
            }
            XCTAssertEqual(finish, .length); XCTAssertEqual(outputCount, 2)
            await engine.shutdown()
            XCTAssertEqual(backend.bytesReserved, 0); XCTAssertEqual(backend.bytesWired, 0)
        }
    }
}

private final class LayerSubmissionFaultModel: CBv2SteppableModel, @unchecked Sendable {
    private let lock = NSLock()
    private var failOnCall: Int?
    private var calls = 0
    init(failOnCall: Int) { self.failOnCall = failOnCall }
    func allowValidCalls() { lock.withLock { failOnCall = nil } }
    func forward(tokens: MLXArray, caches: [any CBv2AttendingLayerCache]) -> MLXArray {
        let fail = lock.withLock { calls += 1; return calls == failOnCall }
        let length = tokens.dim(1)
        let plan = Qwen4ExpLayerSubmission.plan(batchSize: 1, sequenceWidth: length,
            hasEmbeddings: false, hasPositions: false, caches: caches,
            environment: [Qwen4ExpLayerSubmission.flag: "1"])
        let queries = MLXArray.ones([1, 2, length, 64], dtype: .float32)
        let keys = MLXArray.ones([1, 1, length, 64], dtype: .bfloat16)
        var output = queries
        for (index, cache) in caches.enumerated() {
            output = cache.updateAndAttend(queries: queries, keys: keys,
                values: fail && index == 1 ? keys.asType(.float32) : keys,
                scale: 0.125, sinks: nil)
            plan?.submit(output.transposed(0, 2, 1, 3).reshaped(1, length, 128))
        }
        return broadcast(MLXArray([Float(0), Float(1)]).reshaped(1, 1, 2), to: [1, length, 2])
            + sum(output) * Float(0)
    }
}
