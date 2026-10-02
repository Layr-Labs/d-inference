import MLX
import Testing

@testable import MLXLMCommon

@Suite("Paged native KV dtype layout", .serialized)
struct CBv2PagedNativeDTypeTests {
    private func kind(window: Int? = nil, shares: Int? = nil) -> CBv2LayerKind {
        .init(attention: window.map { .slidingWindow($0) } ?? .full,
              sharesKVWithLayer: shares, headDim: 64, kvHeads: 1, queryHeads: 2)
    }

    @Test("equal geometry preserves separate native dtype and window roots")
    func independentRootsAndBytes() throws {
        let kinds = [kind(), kind(), kind(window: 16), kind(shares: 0)]
        let types: [DType] = [.bfloat16, .float32, .bfloat16, .bfloat16]
        let backend = try PagedKVBackend(layerKinds: kinds, config: .init(
            capacityBytes: 4 << 20, maxPrefillChunk: 16,
            nominalMaxSequenceLength: 64, maxBufferLength: 4 << 20,
            segmentSizeBytes: 32768, layerDTypes: types))
        let pool = backend.pool
        #expect(pool.groupKeys.count == 3)
        #expect(pool.groupKey(forLayer: 0) != pool.groupKey(forLayer: 1))
        #expect(pool.groupKey(forLayer: 0) != pool.groupKey(forLayer: 2))
        #expect(pool.groupKey(forLayer: 0) == pool.groupKey(forLayer: 3))
        #expect(pool.layerDTypes == types)
        let rows = try backend.makeSequenceState(layerKinds: kinds, promptLength: 16, maxLength: 64)
        defer { backend.release(rows) }
        #expect(rows[3] == nil)
        for index in 0 ..< 3 {
            let row = try #require(rows[index] as? PagedSequenceKV)
            #expect(row.groupKey == pool.groupKey(forLayer: index))
            let keys = (MLXArray(0 ..< 1024).asType(.float32) / 127)
                .reshaped([1, 1, 16, 64]).asType(types[index])
            let values = (keys + 1).asType(types[index])
            _ = row.update(keys: keys, values: values)
            let snapshot = row.snapshot()
            #expect(snapshot.keys.dtype == types[index])
            #expect(snapshot.values.dtype == types[index])
            #expect(snapshot.keys.asData(access: .copy).data == keys.asData(access: .copy).data)
            #expect(snapshot.values.asData(access: .copy).data == values.asData(access: .copy).data)
        }
        let fullBytes = 2 * 64 * 64 * (2 + 4)
        let windowBytes = 2 * 32 * 64 * 2
        #expect(backend.bytesReserved == fullBytes + windowBytes)
        #expect(pool.segmentStorageSnapshot!.committedBytes >= backend.bytesReserved)
    }

    @Test("storage and admission use the same mixed element widths")
    func admissionMatchesNativeTable() async throws {
        let kinds = [kind(), kind(), kind(shares: 0)]
        let backend = try PagedKVBackend(layerKinds: kinds, config: .init(
            capacityBytes: 1 << 20, maxPrefillChunk: 16,
            segmentSizeBytes: 32768, layerDTypes: [.bfloat16, .float32, .bfloat16]))
        let engine = EngineV2(
            model: CBv2SchedScriptedModel(), layerKinds: kinds, backend: backend,
            cacheProvider: CBv2LayerCacheBank(caches: backend.makeLayerCaches()),
            sampler: CBv2GreedySampler(), admissionConfig: .init(
                watermarkFraction: 0, elementBytes: 1, layerElementBytes: [1, 1, 1]))
        #expect(engine.admissionForTesting.estimatedBytes(forTokens: 16) == 2 * 16 * 64 * (2 + 4))
        await engine.shutdown()
    }

    @Test("invalid dtype tables and mismatched borrowed native layouts refuse construction")
    func malformedTables() throws {
        let kinds = [kind(), kind(shares: 0)]
        for types: [DType] in [[.float16], [.float16, .float32], [.uint32, .uint32]] {
            #expect(throws: CBv2KVError.self) {
                try PagedKVBackend(layerKinds: kinds, config: .init(
                    capacityBytes: 1 << 20, segmentSizeBytes: 32768, layerDTypes: types))
            }
        }
        let fixed = try PagedKVBackend(layerKinds: [kind(), kind(window: 16)], config: .init(
            capacityBytes: 1 << 20, dtype: .bfloat16, maxPrefillChunk: 16))
        #expect(fixed.pool.groupKeys.count == 1, "uniform fixed reference retains its original grouping")
    }
}

private final class NativeKVProbeFixture: CBv2SteppableModel {
    let types: [DType]
    let changeOnDecode: Bool
    let asymmetric: Bool
    init(types: [DType], changeOnDecode: Bool = false, asymmetric: Bool = false) {
        self.types = types
        self.changeOnDecode = changeOnDecode
        self.asymmetric = asymmetric
    }

    func forward(tokens: MLXArray, caches: [any CBv2AttendingLayerCache]) -> MLXArray {
        let count = tokens.dim(1)
        var output = MLXArray.zeros([1, count, 8])
        for (index, cache) in caches.enumerated() {
            let dtype: DType = changeOnDecode && count == 1 ? .float32 : types[index]
            let keys = MLXArray.ones([1, 1, count, 64], dtype: dtype)
            let values = asymmetric ? keys.asType(.float16) : keys
            let queries = MLXArray.ones([1, 2, count, 64], dtype: dtype)
            output = cache.updateAndAttend(queries: queries, keys: keys, values: values,
                                          scale: 0.125, sinks: nil)
        }
        return output
    }
}

@Suite("Loaded native KV dtype probe", .serialized)
struct CBv2NativeKVTypeProbeTests {
    private let kinds = [
        CBv2LayerKind(attention: .full, headDim: 64, kvHeads: 1, queryHeads: 2),
        CBv2LayerKind(attention: .slidingWindow(16), headDim: 64, kvHeads: 1, queryHeads: 2)
    ]

    private func caches() -> [any CBv2AttendingLayerCache] {
        kinds.enumerated().map { CBv2LayerCache(layerIndex: $0, kind: $1) }
    }

    @Test("both phases observe actual mixed storage types and release every private row")
    func recordsAndDrains() throws {
        let caches = caches()
        let result = try CBv2NativeKVTypeProbe.run(
            model: NativeKVProbeFixture(types: [.float32, .bfloat16]), layerKinds: kinds, caches: caches)
        #expect(result.layerDTypes == [.float32, .bfloat16])
        #expect(result.observations.map(\.phase) == [.prefill, .prefill, .decode, .decode])
        #expect(result.observations.map { $0.keysShape[2] } == [2, 2, 1, 1])
        #expect(result.observations.allSatisfy { $0.keysDType == $0.valuesDType })
        #expect(caches.allSatisfy { $0.rows.isEmpty })
    }

    @Test("changed or asymmetric types fail before any paged allocation and unbind all rows")
    func refusesUnstableTypes() throws {
        for fixture in [
            NativeKVProbeFixture(types: [.bfloat16, .bfloat16], changeOnDecode: true),
            NativeKVProbeFixture(types: [.bfloat16, .bfloat16], asymmetric: true)
        ] {
            let caches = caches()
            #expect(throws: CBv2KVError.self) {
                try CBv2NativeKVTypeProbe.run(model: fixture, layerKinds: kinds, caches: caches)
            }
            #expect(caches.allSatisfy { $0.rows.isEmpty })
        }
    }

    @Test("throwing callback preserves phase/count/native result and releases rows")
    func callbackMatchesModelEntry() throws {
        let model = NativeKVProbeFixture(types: [.float32, .bfloat16])
        let oldCaches = caches()
        let expected = try CBv2NativeKVTypeProbe.run(
            model: model, layerKinds: kinds, caches: oldCaches)
        let newCaches = caches()
        var phases: [CBv2NativeKVTypeProbe.Phase] = []
        var counts: [Int] = []
        let actual = try CBv2NativeKVTypeProbe.run(layerKinds: kinds, caches: newCaches) {
            phase, count, supplied in
            #expect(zip(supplied, newCaches).allSatisfy { $0.0 === $0.1 })
            #expect(supplied.allSatisfy { $0.rows.count == 1 })
            phases.append(phase); counts.append(count)
            let tokens = MLXArray(Array(repeating: Int32(0), count: count)).reshaped([1, count])
            return model.forward(tokens: tokens, caches: supplied)
        }
        #expect(actual == expected)
        #expect(phases == [.prefill, .decode] && counts == [2, 1])
        #expect(oldCaches.allSatisfy { $0.rows.isEmpty })
        #expect(newCaches.allSatisfy { $0.rows.isEmpty })
    }

    private enum CallbackFailure: Error { case refused }

    @Test("callback failure after partial native work unbinds every private row")
    func callbackThrowUnbindsRows() throws {
        for failingPhase: CBv2NativeKVTypeProbe.Phase in [.prefill, .decode] {
            let model = NativeKVProbeFixture(types: [.float32, .bfloat16])
            let caches = caches()
            var phases: [CBv2NativeKVTypeProbe.Phase] = []
            #expect(throws: CallbackFailure.self) {
                try CBv2NativeKVTypeProbe.run(layerKinds: kinds, caches: caches) {
                    phase, count, supplied in
                    phases.append(phase)
                    let tokens = MLXArray(Array(repeating: Int32(0), count: count)).reshaped([1, count])
                    let output = model.forward(tokens: tokens, caches: supplied)
                    if phase == failingPhase { throw CallbackFailure.refused }
                    return output
                }
            }
            #expect(phases == (failingPhase == .prefill ? [.prefill] : [.prefill, .decode]))
            #expect(caches.allSatisfy { $0.rows.isEmpty })
        }
    }

    @Test("callback path retains malformed-cache and changing/asymmetric dtype refusal")
    func callbackRefusals() throws {
        var invoked = false
        #expect(throws: CBv2KVError.self) {
            try CBv2NativeKVTypeProbe.run(layerKinds: kinds, caches: []) { _, _, _ in
                invoked = true
                throw CallbackFailure.refused
            }
        }
        #expect(!invoked)
        for model in [
            NativeKVProbeFixture(types: [.bfloat16, .bfloat16], changeOnDecode: true),
            NativeKVProbeFixture(types: [.bfloat16, .bfloat16], asymmetric: true)
        ] {
            let caches = caches()
            #expect(throws: CBv2KVError.self) {
                try CBv2NativeKVTypeProbe.run(layerKinds: kinds, caches: caches) { _, count, supplied in
                    let tokens = MLXArray(Array(repeating: Int32(0), count: count)).reshaped([1, count])
                    return model.forward(tokens: tokens, caches: supplied)
                }
            }
            #expect(caches.allSatisfy { $0.rows.isEmpty })
        }
    }

}
