import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Native diffusion complete encrypted store", .serialized)
struct NativeDiffusionCheckpointStoreTests {
    @Test func boundNativeMediaMayProbeButUnboundAndForeignControlsDoNot() async throws {
        let f = try NativeDiffusionCheckpointFixture()
        defer { f.remove() }
        let store = try f.makeStore()
        let binding = try CBv2HybridPrefixIdentity(digest: Data(repeating: 17, count: 32))
        let media = CBv2MultimodalInput(spans: [.init(tokenOffset: 1, length: 2)], embeddings: {
            Issue.record("Store policy must not evaluate embeddings")
            return []
        })
        var bound = f.request()
        bound.multimodal = media
        bound.hybridPrefixIdentity = binding
        var unbound = bound; unbound.hybridPrefixIdentity = nil
        var causal = bound; causal.multimodal?.attention = .causal
        var deepstack = bound; deepstack.multimodal?.deepstackEmbeddings = { [] }
        var orphan = bound; orphan.multimodal = nil
        var empty = bound; empty.multimodal?.spans = []
        for (index, request) in [bound, unbound, causal, deepstack, orphan, empty].enumerated() {
            let result = await store.stageNativeBlock(requestID: .init(UInt64(80 + index)), request: request,
                reserveReadScratch: {
                    Issue.record("Empty index must not allocate read scratch")
                    throw CancellationError()
                }, makeImportPlan: { _ in
                    Issue.record("Empty index must not plan an import")
                    throw CancellationError()
                })
            #expect(result.disposition == (index == 0 ? .missAbsent : .skippedPolicy))
        }
        #expect(store.stats().filesRead == 0 && store.stats().stages == 0)
        await store.closeAndWait()
        await f.engine.shutdown()
        #expect(await f.budget.outstandingReservedBytes() == 0 && f.engine.capacity().kvBytesReserved == 0)
    }

    @Test func restartAdoptsExactAndAppendedPrefixesWithoutChangingNativeState() async throws {
        let f = try NativeDiffusionCheckpointFixture()
        defer { f.remove() }
        let donor = try f.makeStore()
        #expect(try await f.donate(donor) == [512], "Native diffusion can preserve the full prompt, unlike AR last-logit replay")
        await donor.closeAndWait()
        let restored = try f.makeStore()
        #expect(restored.stats().entries == 1)
        for (id, appended) in [(UInt64(11), false), (UInt64(12), true)] {
            try await adoptAndCompare(f, store: restored, request: f.request(appended: appended), id: id)
        }
        await restored.closeAndWait()
        #expect(await f.budget.outstandingReservedBytes() == 0)
        #expect(f.engine.capacity().kvBytesReserved == 0)
        await f.engine.shutdown()
    }

    private func adoptAndCompare(_ f: NativeDiffusionCheckpointFixture, store: SSDHybridCheckpointStore,
                                 request: CBv2Request, id: UInt64) async throws {
        let result = await store.stageNativeBlock(requestID: .init(id), request: request,
            reserveReadScratch: { try f.engine.reserveNativeCheckpointReadScratch() },
            makeImportPlan: { try f.plan($0, request: request) })
        #expect(result.staged)
        let staged = try #require(store.takeNativeStaged(requestID: .init(id), tokens: request.promptTokens,
            cacheSalt: request.cacheSalt, maximumSequenceLength: request.promptTokens.count + request.maxTokens))
        #expect(store.takeNativeStaged(requestID: .init(id), tokens: request.promptTokens,
            cacheSalt: request.cacheSalt, maximumSequenceLength: staged.maximumSequenceLength) == nil)
        let checkpoint = try f.codec.adopt(staged, prefixIdentity: f.prefixIdentity())
        let cache = try f.model.restorePrefix(checkpoint, identity: f.prefixIdentity(),
            promptTokenIds: MLXArray(request.promptTokens).asType(.int32).reshaped(1, request.promptTokens.count))
        let cold = try f.coldCache()
        try MLX.withError { errors in
            for (a, b) in zip(cache.snapshots(), cold.snapshots()) {
                #expect(a.keys.asArray(Float.self).map(\.bitPattern) == b.keys.asArray(Float.self).map(\.bitPattern))
                #expect(a.values.asArray(Float.self).map(\.bitPattern) == b.values.asArray(Float.self).map(\.bitPattern))
            }
            let suffix = Array(request.promptTokens.dropFirst(f.tokens.count))
            let continuation = suffix.isEmpty ? [11] : suffix
            let next = MLXArray(continuation).asType(.int32).reshaped(1, continuation.count)
            let a = try f.model.encode(tokenIds: next, cache: cache, encoderParameters: f.scalars)
            let b = try f.model.encode(tokenIds: next, cache: cold, encoderParameters: f.scalars)
            try errors.check(); eval(a, b); try errors.check()
            #expect(a.asArray(Float.self).map(\.bitPattern) == b.asArray(Float.self).map(\.bitPattern))
            let canvas = MLXArray([Int32(2), 3, 5, 7]).reshaped(1, 4)
            let logits = try f.model.denoise(canvasIds: canvas, cache: cache)
            let control = try f.model.denoise(canvasIds: canvas, cache: cold)
            try errors.check(); eval(logits, control); try errors.check()
            #expect(logits.asArray(Float.self).map(\.bitPattern) == control.asArray(Float.self).map(\.bitPattern))
        }
        #expect(await f.budget.outstandingReservedBytes() > 0, "Consumed ticket must stay charged through its borrowing request")
        #expect(store.stats().stageConsumptions > 0)
    }

    @Test func scopeCapacityCancellationAndTamperNeverPublishAStage() async throws {
        let f = try NativeDiffusionCheckpointFixture()
        defer { f.remove() }
        let store = try f.makeStore()
        #expect(try await f.donate(store) == [512])
        let wrong = f.request(scope: "other-tenant")
        let absent = await store.stageNativeBlock(requestID: .init(21), request: wrong,
            reserveReadScratch: { try f.engine.reserveNativeCheckpointReadScratch() },
            makeImportPlan: { try f.plan($0, request: wrong) })
        #expect(!absent.staged && store.stats().filesRead == 0)
        let request = f.request()
        f.engine.updateKVBytesCapacity(1)
        let refused = await store.stageNativeBlock(requestID: .init(22), request: request,
            reserveReadScratch: { try f.engine.reserveNativeCheckpointReadScratch() },
            makeImportPlan: { try f.plan($0, request: request) })
        #expect(refused.disposition == .skippedCapacity && store.stats().filesRead == 0)
        f.engine.updateKVBytesCapacity(256 << 20)
        let cancelled = await store.stageNativeBlock(requestID: .init(23), request: request,
            reserveReadScratch: { throw CancellationError() }, makeImportPlan: { try f.plan($0, request: request) })
        #expect(cancelled.disposition == .skippedPolicy)
        let ready = await store.stageNativeBlock(requestID: .init(24), request: request,
            reserveReadScratch: { try f.engine.reserveNativeCheckpointReadScratch() }, makeImportPlan: { try f.plan($0, request: request) })
        #expect(ready.staged)
        await store.abandonStaging(requestID: .init(24))
        #expect(await f.budget.outstandingReservedBytes() == 0)
        let file = try f.file(store)
        var bytes = try Data(contentsOf: file); bytes[bytes.count - 1] ^= 1; try bytes.write(to: file)
        let corrupt = await store.stageNativeBlock(requestID: .init(25), request: request,
            reserveReadScratch: { try f.engine.reserveNativeCheckpointReadScratch() }, makeImportPlan: { try f.plan($0, request: request) })
        #expect(corrupt.disposition == .missCorrupt)
        #expect(store.takeNativeStaged(requestID: .init(25), tokens: request.promptTokens,
            cacheSalt: request.cacheSalt, maximumSequenceLength: 520) == nil)
        await store.closeAndWait()
        #expect(await f.budget.outstandingReservedBytes() == 0 && f.engine.capacity().kvBytesReserved == 0)
        await f.engine.shutdown()
    }

    @Test func missingProcessAuthorityAndIncompatibleRequestCannotConsumeOrDeleteGoodData() async throws {
        let f = try NativeDiffusionCheckpointFixture()
        defer { f.remove() }
        let store = try f.makeStore()
        #expect(try await f.donate(store) == [512])
        let file = try f.file(store)
        let original = try Data(contentsOf: file)
        let unfunded = try f.makeStore(useGlobalBudget: false)
        #expect(try await f.donate(unfunded).isEmpty)
        let request = f.request()
        let refused = await unfunded.stageNativeBlock(requestID: .init(31), request: request,
            reserveReadScratch: { try f.engine.reserveNativeCheckpointReadScratch() },
            makeImportPlan: { try f.plan($0, request: request) })
        #expect(refused.disposition == .skippedCapacity && unfunded.stats().filesRead == 0)
        await unfunded.closeAndWait()
        let empty = f.request(scope: "")
        let emptyResult = await store.stageNativeBlock(requestID: .init(32), request: empty,
            reserveReadScratch: { try f.engine.reserveNativeCheckpointReadScratch() },
            makeImportPlan: { try f.plan($0, request: empty) })
        #expect(emptyResult.disposition == .skippedPolicy && store.stats().filesRead == 0)
        var overflow = request
        overflow.maxTokens = Int.max
        let overflowRequest = overflow
        let incompatible = await store.stageNativeBlock(requestID: .init(33), request: overflowRequest,
            reserveReadScratch: { try f.engine.reserveNativeCheckpointReadScratch() },
            makeImportPlan: { try f.plan($0, request: overflowRequest) })
        #expect(incompatible.disposition == .skippedPolicy && store.stats().entries == 1)
        let ready = await store.stageNativeBlock(requestID: .init(34), request: request,
            reserveReadScratch: { try f.engine.reserveNativeCheckpointReadScratch() },
            makeImportPlan: { try f.plan($0, request: request) })
        #expect(ready.staged)
        #expect(store.takeStaged(requestID: .init(34), tokens: request.promptTokens,
            cacheSalt: request.cacheSalt, maximumSequenceLength: 520) == nil,
            "An AR consumer must not adopt native state")
        await store.abandonStaging(requestID: .init(34))
        await store.closeAndWait()
        #expect(try Data(contentsOf: file) == original)
        #expect(await f.budget.outstandingReservedBytes() == 0 && f.engine.capacity().kvBytesReserved == 0)
        await f.engine.shutdown()
    }
}
