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
