import Foundation
import Testing
@testable import MLX
@testable import MLXLMCommon
@testable import ProviderCore

// P3-foundation: the [KVCache] <-> bytes serializer. Verifies faithful
// byte round-trip (incl. bf16), resume-equivalence for the attention
// caches, unsupported-type rejection, and end-to-end through
// EncryptedKVStore (the path the SSD tier will use).

private let H = 2, D = 4

private func simpleCache(tokens n: Int, base: Float = 0, dtype: DType = .float32) -> KVCacheSimple {
    let c = KVCacheSimple()
    let k = MLXArray((0..<(H * n * D)).map { base + Float($0 % 17) }, [1, H, n, D]).asType(dtype)
    let v = MLXArray((0..<(H * n * D)).map { base + Float($0 % 13) + 100 }, [1, H, n, D]).asType(dtype)
    _ = c.update(keys: k, values: v)
    eval(c.innerState())
    return c
}

private func rotatingCache(feed n: Int, maxSize: Int = 4) -> RotatingKVCache {
    let c = RotatingKVCache(maxSize: maxSize, keep: 0, step: maxSize)
    for t in 0..<n {
        let k = MLXArray(Array(repeating: Float(t), count: H * D), [1, H, 1, D])
        let v = MLXArray(Array(repeating: Float(t) + 100, count: H * D), [1, H, 1, D])
        _ = c.update(keys: k, values: v)
        eval(c.innerState())
    }
    return c
}

private func arraysEqual(_ a: [MLXArray], _ b: [MLXArray]) -> Bool {
    guard a.count == b.count else { return false }
    for (x, y) in zip(a, b) {
        if x.shape != y.shape { return false }
        if x.asType(.float32).asArray(Float.self) != y.asType(.float32).asArray(Float.self) { return false }
    }
    return true
}

@Test
func serializerRoundTripsKVCacheSimpleState() throws {
    let original = simpleCache(tokens: 6)
    let (chunks, layout) = try KVCacheSerializer.serialize([original])
    #expect(layout.layers.count == 1)
    #expect(layout.layers[0].className == "KVCache")
    #expect(chunks.count == 2)  // keys + values

    let restored = try KVCacheSerializer.deserialize(chunks: chunks, layout: layout)
    #expect(restored.count == 1)
    #expect(arraysEqual(restored[0].state, original.state), "state arrays must round-trip byte-exact")
    #expect(restored[0].offset == original.offset)
}

@Test
func serializerPreservesBF16Exactly() throws {
    let original = simpleCache(tokens: 5, dtype: .bfloat16)
    #expect(original.state[0].dtype == .bfloat16)

    let (chunks, layout) = try KVCacheSerializer.serialize([original])
    #expect(layout.layers[0].arrays[0].dtype == "bfloat16")

    let restored = try KVCacheSerializer.deserialize(chunks: chunks, layout: layout)
    #expect(restored[0].state[0].dtype == .bfloat16, "dtype must survive round-trip")
    #expect(arraysEqual(restored[0].state, original.state), "bf16 bytes must round-trip exactly")
}

@Test
func serializerResumeEquivalenceSimple() throws {
    // Strong check: a reconstructed cache continues generation identically.
    let original = simpleCache(tokens: 6)
    let (chunks, layout) = try KVCacheSerializer.serialize([original])
    let restored = try KVCacheSerializer.deserialize(chunks: chunks, layout: layout)[0]

    let k = MLXArray(Array(repeating: Float(7), count: H * D), [1, H, 1, D])
    let v = MLXArray(Array(repeating: Float(7) + 100, count: H * D), [1, H, 1, D])
    let (ko, vo) = original.update(keys: k, values: v); eval(ko, vo)
    let (kr, vr) = restored.update(keys: k.asType(.float32), values: v.asType(.float32)); eval(kr, vr)
    #expect(ko.asArray(Float.self) == kr.asArray(Float.self), "resume after restore diverged (keys)")
    #expect(vo.asArray(Float.self) == vr.asArray(Float.self), "resume after restore diverged (values)")
}

@Test
func serializerResumeEquivalenceRotatingWrapped() throws {
    // Feed past the window so the circular buffer has wrapped.
    let original = rotatingCache(feed: 10, maxSize: 4)
    let (chunks, layout) = try KVCacheSerializer.serialize([original])
    #expect(layout.layers[0].className == "RotatingKVCache")
    #expect(layout.layers[0].metaState.count == 5)  // keep,maxCacheSize,step,offset,idx

    let restored = try KVCacheSerializer.deserialize(chunks: chunks, layout: layout)[0]

    // Resume both with a multi-token prefill and compare.
    let k = MLXArray((0..<(H * 3 * D)).map { Float(100 + $0) }, [1, H, 3, D])
    let v = MLXArray((0..<(H * 3 * D)).map { Float(200 + $0) }, [1, H, 3, D])
    let (ko, vo) = original.update(keys: k, values: v); eval(ko, vo)
    let (kr, vr) = restored.update(keys: k, values: v); eval(kr, vr)
    #expect(ko.shape == kr.shape, "rotating resume shape diverged")
    #expect(ko.asArray(Float.self) == kr.asArray(Float.self), "rotating resume after restore diverged")
    #expect(vo.asArray(Float.self) == vr.asArray(Float.self))
}

@Test
func serializerMixedHybridLayersEndToEndThroughEncryptedStore() async throws {
    // The checkpoint-tier scenario for Gemma-4 / GPT-OSS: a MIXED layer
    // list (RotatingKVCache sliding-window layers + KVCacheSimple full
    // layers) must survive serialize -> encrypt -> decrypt -> deserialize
    // -> restore, and a subsequent multi-token prefill must match a
    // never-snapshotted reference on EVERY layer. This is the foundational
    // correctness proof the hybrid wiring depends on.
    //
    // Gemma-4 pattern: 4 sliding (every 5th full). maxSize 4, fed past the
    // window so the rotating layers have wrapped (idx mid-buffer).
    func buildLayers() -> [any KVCache] {
        let r1 = rotatingCache(feed: 10, maxSize: 4)
        let r2 = rotatingCache(feed: 10, maxSize: 4)
        let s1 = simpleCache(tokens: 10)
        let r3 = rotatingCache(feed: 10, maxSize: 4)
        let s2 = simpleCache(tokens: 10)
        return [r1, r2, s1, r3, s2]
    }
    let original = buildLayers()
    let reference = buildLayers()  // identical construction → identical state

    let (chunks, layout) = try KVCacheSerializer.serialize(original)
    #expect(layout.layers.map { $0.className }
        == ["RotatingKVCache", "RotatingKVCache", "KVCache", "RotatingKVCache", "KVCache"])
    let layoutJSON = String(data: try JSONEncoder().encode(layout), encoding: .utf8)!

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("dbkv-mixed-\(UUID().uuidString).darkbloom-kv")
    defer { try? FileManager.default.removeItem(at: url) }
    let kek = KVCacheKEK(
        wrapper: InMemoryKeyWrappingService(),
        storage: InMemoryWrappedKEKStorage(identifier: UUID().uuidString))
    let meta = EncryptedKVStoreMetadata(
        modelHash: "sha256:hybrid", modelDtype: "float32", modelArch: "Gemma4",
        vocabSize: 1000, numLayers: original.count, kvHeads: H, headDim: D,
        tokenCount: 10, tokenPrefixHash: "sha256:mixed", kvCacheClass: "mixed",
        metaState: [layoutJSON], chunkPlaintextSizes: chunks.map { $0.count })
    try await EncryptedKVStore.write(to: url, metadata: meta, chunks: chunks, kek: kek)

    let (readMeta, readChunks) = try await EncryptedKVStore.read(from: url, kek: kek)
    let readLayout = try JSONDecoder().decode(KVCacheLayout.self, from: Data(readMeta.metaState[0].utf8))
    let restored = try KVCacheSerializer.deserialize(chunks: readChunks, layout: readLayout)

    #expect(restored.count == reference.count)
    // Resume each layer with the SAME 3-token prefill; restored must equal
    // the reference layer-for-layer (order + content), proving no layer was
    // scrambled, swapped, or lost across the encrypted round-trip.
    let k = MLXArray((0..<(H * 3 * D)).map { Float(100 + $0) }, [1, H, 3, D])
    let v = MLXArray((0..<(H * 3 * D)).map { Float(200 + $0) }, [1, H, 3, D])
    for (i, (res, ref)) in zip(restored, reference).enumerated() {
        let (kr, vr) = res.update(keys: k, values: v); eval(kr, vr)
        let (kf, vf) = ref.update(keys: k, values: v); eval(kf, vf)
        #expect(kr.shape == kf.shape, "layer \(i) (\(layout.layers[i].className)) shape diverged")
        #expect(kr.asArray(Float.self) == kf.asArray(Float.self),
                "layer \(i) (\(layout.layers[i].className)) keys diverged after encrypted restore")
        #expect(vr.asArray(Float.self) == vf.asArray(Float.self),
                "layer \(i) (\(layout.layers[i].className)) values diverged after encrypted restore")
    }
}

@Test
func serializerRejectsMambaForSSD() {
    // Recurrent caches are RAM-tier only (their metaState setter traps;
    // reconstruction is internal to MLXLMCommon). The serializer must
    // refuse them so a hybrid model isn't half-persisted.
    let mamba = MambaCache()
    mamba.state = [MLXArray((0..<8).map { Float($0) }, [1, 8]),
                   MLXArray((0..<8).map { Float($0) + 50 }, [1, 8])]
    eval(mamba.innerState())

    #expect(KVCacheSerializer.className(mamba) == nil, "MambaCache must not be SSD-serializable")
    #expect(KVCacheSerializer.areSupported([mamba]) == false)
    #expect(throws: KVCacheSerializerError.self) {
        _ = try KVCacheSerializer.serialize([mamba])
    }
    // A hybrid stack (Mamba + attention) must also be refused as a whole.
    #expect(KVCacheSerializer.areSupported([mamba, simpleCache(tokens: 4)]) == false)
}

@Test
func serializerRejectsUnsupportedType() {
    // ChunkedKVCache is a KVCacheSimple subclass but explicitly unsupported.
    let chunked = ChunkedKVCache(chunkSize: 8)
    #expect(KVCacheSerializer.className(chunked) == nil)
    #expect(KVCacheSerializer.areSupported([chunked]) == false)
    #expect(throws: KVCacheSerializerError.self) {
        _ = try KVCacheSerializer.serialize([chunked])
    }
    // Pure attention + sliding stacks ARE supported.
    #expect(KVCacheSerializer.areSupported([simpleCache(tokens: 4), rotatingCache(feed: 6)]) == true)
}

@Test
func serializerEndToEndThroughEncryptedStore() async throws {
    // The real SSD path: serialize -> EncryptedKVStore.write (layout in
    // metaState) -> read -> deserialize -> resume-equivalent.
    let original = simpleCache(tokens: 6)
    let (chunks, layout) = try KVCacheSerializer.serialize([original])
    let layoutJSON = String(data: try JSONEncoder().encode(layout), encoding: .utf8)!

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("dbkv-ser-\(UUID().uuidString).darkbloom-kv")
    defer { try? FileManager.default.removeItem(at: url) }
    let kek = KVCacheKEK(
        wrapper: InMemoryKeyWrappingService(),
        storage: InMemoryWrappedKEKStorage(identifier: UUID().uuidString)
    )

    let meta = EncryptedKVStoreMetadata(
        modelHash: "sha256:test", modelDtype: "float32", modelArch: "Llama",
        vocabSize: 1000, numLayers: 1, kvHeads: H, headDim: D, tokenCount: 6,
        tokenPrefixHash: "sha256:abc", kvCacheClass: "KVCache",
        metaState: [layoutJSON],
        chunkPlaintextSizes: chunks.map { $0.count }
    )
    try await EncryptedKVStore.write(to: url, metadata: meta, chunks: chunks, kek: kek)

    let (readMeta, readChunks) = try await EncryptedKVStore.read(from: url, kek: kek)
    let readLayout = try JSONDecoder().decode(KVCacheLayout.self, from: Data(readMeta.metaState[0].utf8))
    let restored = try KVCacheSerializer.deserialize(chunks: readChunks, layout: readLayout)[0]

    #expect(arraysEqual(restored.state, original.state),
            "KV survived serialize -> encrypt -> decrypt -> deserialize")
}

// MARK: - Shape binding (G1): layout shapes must match the live model

@Test
func validateLayoutAcceptsMatchingShapes() throws {
    // simpleCache uses [1, H, n, D] => kvHeads=H, headDim=D.
    let (_, layout) = try KVCacheSerializer.serialize([simpleCache(tokens: 6)])
    try KVCacheSerializer.validateLayout(layout, kvHeads: H, headDim: D)  // must not throw
}

@Test
func validateLayoutRejectsWrongKvHeadsOrHeadDim() throws {
    let (_, layout) = try KVCacheSerializer.serialize([simpleCache(tokens: 6)])
    // A self-consistent file whose shape disagrees with the live model must
    // be refused before its KV is seeded into attention.
    #expect(throws: KVCacheSerializerError.self) {
        try KVCacheSerializer.validateLayout(layout, kvHeads: H + 1, headDim: D)
    }
    #expect(throws: KVCacheSerializerError.self) {
        try KVCacheSerializer.validateLayout(layout, kvHeads: H, headDim: D + 1)
    }
}

@Test
func validateLayoutPerLayerAcceptsHeterogeneousModel() throws {
    // REGRESSION (real Gemma-4 shape): the model interleaves sliding layers
    // [kvHeads=8, headDim=256] and full layers [kvHeads=2, headDim=512]. A
    // single (kvHeads, headDim) pair CANNOT describe it — the scalar guard
    // would reject the model's own files and silently disable the SSD cache.
    // Build a mixed 3-layer cache and validate per-layer.
    func cache(kv: Int, hd: Int) -> KVCacheSimple {
        let c = KVCacheSimple()
        let k = MLXArray((0..<(kv * 5 * hd)).map { Float($0 % 7) }, [1, kv, 5, hd])
        let v = MLXArray((0..<(kv * 5 * hd)).map { Float($0 % 9) }, [1, kv, 5, hd])
        _ = c.update(keys: k, values: v); eval(c.innerState())
        return c
    }
    let layers: [any KVCache] = [cache(kv: 8, hd: 256), cache(kv: 2, hd: 512), cache(kv: 8, hd: 256)]
    let (_, layout) = try KVCacheSerializer.serialize(layers)
    let shapes = [[8, 256], [2, 512], [8, 256]]

    // Per-layer guard accepts the heterogeneous model.
    try KVCacheSerializer.validateLayout(layout, layerShapes: shapes)

    // The OLD scalar guard would WRONGLY reject it (proves the bug existed):
    #expect(throws: KVCacheSerializerError.self) {
        try KVCacheSerializer.validateLayout(layout, kvHeads: 8, headDim: 256)
    }
}

@Test
func validateLayoutPerLayerRejectsMismatchAndCount() throws {
    func cache(kv: Int, hd: Int) -> KVCacheSimple {
        let c = KVCacheSimple()
        let k = MLXArray(Array(repeating: Float(1), count: kv * 3 * hd), [1, kv, 3, hd])
        _ = c.update(keys: k, values: k); eval(c.innerState())
        return c
    }
    let (_, layout) = try KVCacheSerializer.serialize([cache(kv: 8, hd: 256), cache(kv: 2, hd: 512)])
    // Wrong per-layer shape (swapped order) → reject.
    #expect(throws: KVCacheSerializerError.self) {
        try KVCacheSerializer.validateLayout(layout, layerShapes: [[2, 512], [8, 256]])
    }
    // Layer-count mismatch (foreign file) → reject.
    #expect(throws: KVCacheSerializerError.self) {
        try KVCacheSerializer.validateLayout(layout, layerShapes: [[8, 256]])
    }
    // Correct → accept.
    try KVCacheSerializer.validateLayout(layout, layerShapes: [[8, 256], [2, 512]])
}

// MARK: - metaState validation (G2): malformed metaState throws, never fatalErrors

@Test
func deserializeRejectsWrongCountRotatingMetaState() throws {
    let (chunks, layout) = try KVCacheSerializer.serialize([rotatingCache(feed: 3)])
    // RotatingKVCache.metaState setter fatalErrors on count != 5; the
    // serializer must throw (recoverable cold miss) instead of crashing.
    let bad = KVCacheLayout(version: layout.version, layers: [
        KVCacheLayerDescriptor(className: layout.layers[0].className,
                               metaState: ["1", "2"], arrays: layout.layers[0].arrays)
    ])
    #expect(throws: KVCacheSerializerError.self) {
        _ = try KVCacheSerializer.deserialize(chunks: chunks, layout: bad)
    }
}

@Test
func deserializeRejectsRotatingMaxSizeNone() throws {
    let (chunks, layout) = try KVCacheSerializer.serialize([rotatingCache(feed: 3)])
    var meta = layout.layers[0].metaState
    meta[1] = "None"  // the setter fatalErrors on maxSize=="None"
    let bad = KVCacheLayout(version: layout.version, layers: [
        KVCacheLayerDescriptor(className: layout.layers[0].className,
                               metaState: meta, arrays: layout.layers[0].arrays)
    ])
    #expect(throws: KVCacheSerializerError.self) {
        _ = try KVCacheSerializer.deserialize(chunks: chunks, layout: bad)
    }
}

@Test
func deserializeRejectsNonEmptySimpleMetaState() throws {
    let (chunks, layout) = try KVCacheSerializer.serialize([simpleCache(tokens: 4)])
    // KVCacheSimple.metaState setter fatalErrors unless it is exactly [""].
    let bad = KVCacheLayout(version: layout.version, layers: [
        KVCacheLayerDescriptor(className: layout.layers[0].className,
                               metaState: ["garbage"], arrays: layout.layers[0].arrays)
    ])
    #expect(throws: KVCacheSerializerError.self) {
        _ = try KVCacheSerializer.deserialize(chunks: chunks, layout: bad)
    }
}

// MARK: - Uncatchable-crash residuals: state-setter count + MLXArray init

@Test
func deserializeRejectsWrongStateArrayCount() throws {
    // The state setter fatalErrors unless given exactly 2 arrays; deserialize
    // only checks the aggregate chunk count. A layer with 1 array must throw
    // (cold miss), not crash the process.
    let (chunks, layout) = try KVCacheSerializer.serialize([simpleCache(tokens: 4)])
    let bad = KVCacheLayout(version: layout.version, layers: [
        KVCacheLayerDescriptor(className: layout.layers[0].className,
                               metaState: layout.layers[0].metaState,
                               arrays: [layout.layers[0].arrays[0]])  // 1 array, not 2
    ])
    #expect(throws: KVCacheSerializerError.self) {
        _ = try KVCacheSerializer.deserialize(chunks: [chunks[0]], layout: bad)
    }
}

@Test
func deserializeRejectsShapeByteLengthMismatch() throws {
    // MLXArray(data:shape:dtype:) hard-traps when shape*dtype != byte count.
    // A descriptor whose shape disagrees with its chunk must throw first.
    let (chunks, layout) = try KVCacheSerializer.serialize([simpleCache(tokens: 4)])
    let good = layout.layers[0].arrays[0]
    var badShape = good.shape
    badShape[3] += 1  // inflate headDim so shape*dtype no longer matches the chunk
    let bad = KVCacheLayout(version: layout.version, layers: [
        KVCacheLayerDescriptor(
            className: layout.layers[0].className, metaState: layout.layers[0].metaState,
            arrays: [KVCacheArrayDescriptor(shape: badShape, dtype: good.dtype),
                     layout.layers[0].arrays[1]])
    ])
    #expect(throws: KVCacheSerializerError.self) {
        _ = try KVCacheSerializer.deserialize(chunks: chunks, layout: bad)
    }
}

@Test
func deserializeRejectsNegativeDimShape() throws {
    // A negative dim would trap when computing shape.reduce(1, *); reject it.
    let (chunks, layout) = try KVCacheSerializer.serialize([simpleCache(tokens: 4)])
    let good = layout.layers[0].arrays[0]
    let bad = KVCacheLayout(version: layout.version, layers: [
        KVCacheLayerDescriptor(
            className: layout.layers[0].className, metaState: layout.layers[0].metaState,
            arrays: [KVCacheArrayDescriptor(shape: [1, H, -4, D], dtype: good.dtype),
                     layout.layers[0].arrays[1]])
    ])
    #expect(throws: KVCacheSerializerError.self) {
        _ = try KVCacheSerializer.deserialize(chunks: chunks, layout: bad)
    }
}
