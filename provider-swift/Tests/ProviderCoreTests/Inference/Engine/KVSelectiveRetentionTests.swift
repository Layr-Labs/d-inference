import Foundation
import MLX
import MLXLLM
import Testing
@testable import MLXLMCommon
@testable import ProviderCore

@Suite("Selective KV working-set invariants", .serialized)
struct KVSelectiveRetentionTests {
    private let kind = CBv2LayerKind(attention: .full, hasSinks: true,
                                    headDim: 4, kvHeads: 2, queryHeads: 4)
    private var policy: CBv2SelectiveKVPolicy {
        .init(olderHistoryFraction: 0.5, recentTokens: 16, minimumTokens: 64,
              chunkTokens: 4, pruneInterval: 16, anchorTokens: 4)
    }
    private func positions(_ count: Int, start: Int = 0) -> MLXArray {
        broadcast(MLXArray((start ..< start + count).map(Float.init))
            .reshaped([1, 1, count, 1]), to: [1, 2, count, 4])
    }
    private func row(_ policy: CBv2SelectiveKVPolicy? = nil) -> CBv2SelectiveSequenceKV {
        .init(promptLength: 128, maxLength: 1024, kvHeads: 2, headDim: 4,
              valueHeadDim: 4, policy: policy ?? self.policy)
    }
    private var query: MLXArray { MLXArray.ones([1, 4, 1, 4]) }
    private func tokens(_ row: CBv2SequenceKV) -> [Int] {
        row.snapshot().values[0, 0, 0..., 0].asArray(Float.self).map(Int.init)
    }

    @Test func densePrefillThenPhysicalCompactionPreservesAbsoluteClockAndBands() {
        let state = row()
        _ = state.update(keys: positions(128), values: positions(128))
        let before = state.byteCount
        state.prepareForAttention(queries: query, scale: 0.5, sinks: nil, softcap: nil)
        eval(state.cbv2InnerState())
        let kept = tokens(state)
        #expect(state.absoluteOffset == 128)
        #expect(state.retainedCount < 90)
        #expect(state.byteCount < before)
        #expect(kept == kept.sorted())
        #expect(Set(0 ..< 4).isSubset(of: Set(kept)))
        #expect(Set(112 ..< 128).isSubset(of: Set(kept)))
        _ = state.update(keys: positions(1, start: 128), values: positions(1, start: 128))
        #expect(state.absoluteOffset == 129)
        #expect(tokens(state).last == 128)
    }

    @Test func allocatorReleasesDenseBackingAfterSparseCompaction() {
        let state = CBv2SelectiveSequenceKV(promptLength: 8192, maxLength: 16384,
            kvHeads: 8, headDim: 64, valueHeadDim: 64, policy: .init())
        func populate() {
            _ = state.update(keys: MLXArray.ones([1, 8, 8192, 64]),
                             values: MLXArray.ones([1, 8, 8192, 64]))
            eval(state.cbv2InnerState())
        }
        populate()
        Stream.gpu.synchronize()
        Memory.clearCache()
        let denseLogical = state.byteCount
        let denseActive = Memory.activeMemory
        state.prepareForAttention(queries: MLXArray.ones([1, 64, 1, 64]),
                                  scale: 0.125, sinks: nil, softcap: nil)
        eval(state.cbv2InnerState())
        Stream.gpu.synchronize()
        Memory.clearCache()
        let sparseActive = Memory.activeMemory
        let logicalReduction = denseLogical - state.byteCount
        #expect(logicalReduction > (8 << 20))
        // Independent allocator evidence, not just the row's nbytes counter.
        // Allow small persistent kernel allocations while rejecting an aliased
        // dense source that remains alive after evaluation.
        print("selective-kv allocator: dense=\(denseActive) sparse=\(sparseActive) logical_reduction=\(logicalReduction)")
        #expect(denseActive - sparseActive > logicalReduction / 2)
    }

    @Test func noPruningBeforeCompletePrompt() {
        let state = row()
        _ = state.update(keys: positions(96), values: positions(96))
        state.prepareForAttention(queries: query, scale: 0.5, sinks: nil, softcap: nil)
        #expect(state.retainedCount == 96)
        #expect(tokens(state) == Array(0 ..< 96))
    }

    @Test func gatheredCompactionIncludesSlackWithoutExposingItsTail() {
        let state = row()
        _ = state.update(keys: positions(128), values: positions(128))
        state.prepareForAttention(queries: query, scale: 0.5, sinks: nil, softcap: nil)
        let kept = tokens(state)
        let bytesPerToken = 2 * 2 * 4 * MemoryLayout<Float>.size
        #expect(state.byteCount == (kept.count + 256) * bytesPerToken)
        #expect(state.statistics.lastPruneRetainedStorageBytes == state.byteCount)

        let bytesAfterCompaction = state.byteCount
        _ = state.update(keys: positions(1, start: 128), values: positions(1, start: 128))
        #expect(state.byteCount == bytesAfterCompaction)
        #expect(tokens(state) == kept + [128])
        #expect(state.absoluteOffset == 129)
    }

    @Test func ownedCompactionPreservesNativeDtypesAndUnequalValueWidth() {
        for dtype: DType in [.float16, .bfloat16, .float32] {
            let keys = MLXArray.ones([1, 2, 8, 4], dtype: dtype)
            let values = MLXArray.ones([1, 2, 8, 3], dtype: dtype) * 2
            let state = CBv2FullSequenceKV(compactedKeys: keys, compactedValues: values,
                                           retainedCount: 4, maxLength: 1024)
            #expect(state.byteCount == keys.nbytes + values.nbytes)
            #expect(state.snapshot().keys.dtype == dtype)
            #expect(state.snapshot().values.dtype == dtype)
            #expect(state.snapshot().values.shape == [1, 2, 4, 3])
            _ = state.update(keys: keys[.ellipsis, ..<1, 0...],
                             values: values[.ellipsis, ..<1, 0...] * 3)
            #expect(state.absoluteOffset == 5)
            #expect(state.snapshot().values.shape == [1, 2, 5, 3])
            #expect(state.snapshot().values[.ellipsis, ..<4, 0...]
                .asArray(Float.self).allSatisfy { $0 == 2 })
            #expect(state.snapshot().values[.ellipsis, 4..., 0...]
                .asArray(Float.self).allSatisfy { $0 == 6 })
        }
    }

    @Test func speculativeRejectionDoesNotPruneOrLoseConfirmedValues() {
        let state = row()
        _ = state.update(keys: positions(128), values: positions(128))
        state.prepareForAttention(queries: query, scale: 0.5, sinks: nil, softcap: nil)
        let confirmed = tokens(state)
        state.beginSpeculativeWrite()
        state.prepareForAttention(queries: query, scale: 0.5, sinks: nil, softcap: nil)
        _ = state.update(keys: positions(3, start: 128), values: positions(3, start: 128))
        state.rollback(2)
        state.commitSpeculativeWrite()
        #expect(state.absoluteOffset == 129)
        #expect(tokens(state) == confirmed + [128])
        _ = state.update(keys: positions(1, start: 129), values: positions(1, start: 129))
        #expect(tokens(state).suffix(2) == [128, 129])
    }

    @Test func fullRetentionControlMatchesNativeGQAAndDenominatorOnlySinks() {
        let control = row(.init(olderHistoryFraction: 1, recentTokens: 16, minimumTokens: 64,
                                chunkTokens: 4, pruneInterval: 16, anchorTokens: 4))
        let native = CBv2FullSequenceKV(promptLength: 128, maxLength: 1024,
                                       kvHeads: 2, headDim: 4)
        let sinks = MLXArray([Float(1), 2, 3, 4])
        for (start, count) in [(0, 128), (128, 1), (129, 3)] {
            let q = MLXArray.ones([1, 4, count, 4])
            let k = positions(count, start: start) * 0.01
            let v = positions(count, start: start)
            let actual = CBv2AttentionV1.updateAndAttend(rows: [control], kind: kind,
                queries: q, keys: k, values: v, scale: 0.5, sinks: sinks)
            let expected = CBv2AttentionV1.updateAndAttend(rows: [native], kind: kind,
                queries: q, keys: k, values: v, scale: 0.5, sinks: sinks)
            #expect(allClose(actual, expected, rtol: 1e-6, atol: 1e-6).item(Bool.self))
        }
    }

    @Test func attentionMassRetainsAnOldNeedleUsedByOneGQAHead() {
        let state = row()
        let keys = MLXArray.zeros([1, 2, 128, 4])
        keys[0, 0, 36 ..< 40, 0...] = MLXArray(Float(10))
        _ = state.update(keys: keys, values: positions(128))
        state.prepareForAttention(queries: query, scale: 0.5,
                                  sinks: MLXArray([Float(1), 2, 3, 4]), softcap: nil)
        #expect(Set(36 ..< 40).isSubset(of: Set(tokens(state))))
        #expect(state.retainedCount < 128)
    }

    @Test func sparseBatchedRowsMatchRunningAlone() {
        let a = row(), b = row(), aloneA = row(), aloneB = row()
        for state in [a, b, aloneA, aloneB] {
            _ = state.update(keys: positions(128) * 0.01, values: positions(128))
        }
        let q = concatenated([query, query * 2], axis: 0)
        let k = concatenated([positions(1, start: 128), positions(1, start: 128)], axis: 0)
        let sinks = MLXArray([Float(1), 2, 3, 4])
        let actual = CBv2AttentionV1.updateAndAttend(rows: [a, b], kind: kind,
            queries: q, keys: k, values: k, scale: 0.5, sinks: sinks)
        let expected = [aloneA, aloneB].enumerated().map { index, state in
            CBv2AttentionV1.updateAndAttend(rows: [state], kind: kind,
                queries: q[index ..< index + 1], keys: k[index ..< index + 1],
                values: k[index ..< index + 1], scale: 0.5, sinks: sinks)
        }
        #expect(allClose(actual, concatenated(expected, axis: 0), rtol: 1e-6, atol: 1e-6).item(Bool.self))
        #expect(a.absoluteOffset == 129 && b.absoluteOffset == 129)
    }

    @Test func backendLeavesWindowsNativeAndDisablesPrefixReuse() throws {
        let backend = CBv2ContiguousKVBackend(config: .init(bytesCapacity: 4 << 20,
                                                            selectiveRetention: policy))
        let window = CBv2LayerKind(attention: .slidingWindow(32), headDim: 4,
                                  kvHeads: 2, queryHeads: 4)
        let rows = try backend.makeSequenceState(layerKinds: [kind, window],
                                                  promptLength: 128, maxLength: 1024)
        defer { backend.release(rows) }
        #expect(rows[0] is CBv2SelectiveSequenceKV)
        #expect(rows[1] is CBv2WindowedSequenceKV)
        #expect(backend.prefixReuseBackend == .unknown)
        #expect(!CBv2PrefixReuseCapability.derive(layerKinds: [kind, window],
                                                 backend: backend.prefixReuseBackend).isSupported)
        #expect(backend.bytesReserved > 0)
        let full = try #require(rows[0] as? CBv2SelectiveSequenceKV)
        _ = full.update(keys: positions(128), values: positions(128))
        full.prepareForAttention(queries: query, scale: 0.5, sinks: nil, softcap: nil)
        backend.release(rows)
        #expect(backend.bytesReserved == 0)
        #expect(backend.bytesInUse == 0)
        #expect(backend.selectiveKVStatistics?.pruningEvents == 1)
        #expect(backend.selectiveKVStatistics?.sequenceLayers == 1)
    }

    @Test func gemmaBorrowersUseTheSameSparseOwnerWithoutChangingItsClock() {
        let state = row()
        _ = state.update(keys: positions(128) * 0.01, values: positions(128))
        state.prepareForAttention(queries: query, scale: 0.5, sinks: nil, softcap: nil)
        _ = state.update(keys: positions(1, start: 128) * 0.01, values: positions(1, start: 128))
        let shared = CBv2LayerKind(attention: .full, sharesKVWithLayer: 0,
                                  headDim: 4, kvHeads: 2, queryHeads: 4)
        let actual = CBv2AttentionV1.attendBorrowing(sourceRows: [state], sourceKind: kind,
            kind: shared, queries: query, scale: 0.5, sinks: nil)
        let snapshot = state.snapshot()
        let expected = MLXFast.scaledDotProductAttention(queries: query,
            keys: snapshot.keys, values: snapshot.values, scale: 0.5, mask: .none)
        #expect(allClose(actual, expected, rtol: 1e-6, atol: 1e-6).item(Bool.self))
        #expect(state.absoluteOffset == 129)
    }

    @Test func providerRequiresExplicitBenchmarkAndKnownModel() throws {
        let data = Data("""
        {"model_type":"gpt_oss", "num_hidden_layers":2,
         "num_local_experts":4,"num_experts_per_tok":2,"vocab_size":128,
         "rms_norm_eps":0.00001,"hidden_size":64,"intermediate_size":64,
         "head_dim":64,"num_attention_heads":4,"num_key_value_heads":2,"sliding_window":32}
        """.utf8)
        let model = GPTOSSModel(try JSONDecoder().decode(GPTOSSConfiguration.self, from: data))
        let environment = [EngineV2Factory.selectiveKVEnvKey: "half"]
        let policy = try EngineV2Factory.selectiveKVPolicy(model: model, purpose: .benchmark,
                                                          backend: .contiguous, environment: environment)
        #expect(policy?.olderHistoryFraction == 0.5)
        #expect(throws: (any Error).self) {
            try EngineV2Factory.selectiveKVPolicy(model: model, purpose: .serving,
                                                  backend: .contiguous, environment: environment)
        }
        #expect(throws: (any Error).self) {
            try EngineV2Factory.selectiveKVPolicy(model: model, purpose: .benchmark,
                                                  backend: .auto, environment: environment)
        }
        #expect(try EngineV2Factory.selectiveKVPolicy(model: model, purpose: .serving,
            backend: .auto, environment: [:]) == nil)
    }
}
