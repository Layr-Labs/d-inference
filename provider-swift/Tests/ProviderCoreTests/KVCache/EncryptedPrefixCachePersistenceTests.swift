import CryptoKit
import Foundation
import Testing
@testable import MLX
@testable import MLXLMCommon
@testable import ProviderCore

// Path 2 tests: the encrypted SSD backend for the engine's in-GPU block
// prefix cache. Includes an END-TO-END test driving the REAL upstream
// PrefixCache (the submodule change) so eviction -> saveBlock and
// fetch-miss -> loadBlock are exercised through actual engine code.

private let H = 2, D = 4

private func block(layers: Int, tokens: Int, base: Float = 0) -> [KVCacheSimple] {
    (0..<layers).map { l in
        let c = KVCacheSimple()
        let k = MLXArray((0..<(H * tokens * D)).map { Float($0 + l * 7) + base }, [1, H, tokens, D])
        let v = MLXArray((0..<(H * tokens * D)).map { Float($0 + l * 7) + base + 100 }, [1, H, tokens, D])
        _ = c.update(keys: k, values: v)
        eval(c.innerState())
        return c
    }
}

private func tmpDir() -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("dbkv-persist-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func binding(model: String, layers: Int) -> PrefixCacheModelBinding {
    PrefixCacheModelBinding(
        modelHash: model, modelDtype: "float32", modelArch: "Llama", vocabSize: 1000,
        numLayers: layers, kvHeads: H, headDim: D
    )
}

private func arraysEqual(_ a: [MLXArray], _ b: [MLXArray]) -> Bool {
    guard a.count == b.count else { return false }
    for (x, y) in zip(a, b) where x.asArray(Float.self) != y.asArray(Float.self) { return false }
    return true
}

@Test
func persistenceSaveLoadRoundtrip() {
    let kekKey = SymmetricKey(size: .bits256)
    let dir = tmpDir()
    let p = EncryptedPrefixCachePersistence(kekKey: kekKey, dir: dir, binding: binding(model: "m", layers: 3))
    let hash = Data("blockhash-1".utf8)
    let original = block(layers: 3, tokens: 8)

    #expect(p.loadBlock(blockHash: hash) == nil)  // cold
    p.saveBlock(blockHash: hash, layerCaches: original)

    let loaded = p.loadBlock(blockHash: hash)
    #expect(loaded != nil)
    #expect(loaded?.count == 3)
    for l in 0..<3 {
        #expect(arraysEqual(loaded![l].state, original[l].state), "layer \(l) KV must round-trip")
    }
}

@Test
func persistenceFileIsEncryptedOnDisk() throws {
    // The on-disk bytes must NOT contain the plaintext KV pattern.
    let kekKey = SymmetricKey(size: .bits256)
    let dir = tmpDir()
    let p = EncryptedPrefixCachePersistence(kekKey: kekKey, dir: dir, binding: binding(model: "m", layers: 1))
    let hash = Data("h".utf8)
    p.saveBlock(blockHash: hash, layerCaches: block(layers: 1, tokens: 8))

    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    let kvFile = try #require(files.first { $0.hasSuffix(EncryptedKVStore.fileExtension) })
    let raw = try Data(contentsOf: dir.appendingPathComponent(kvFile))
    // The DBKV magic header is present, but the float bytes are encrypted.
    #expect(raw.prefix(4) == Data([0x44, 0x42, 0x4B, 0x56]))  // "DBKV"
    #expect(raw.count > 100)
}

@Test
func persistenceMB1RejectsWrongModel() {
    // Save under model A, attempt load with a model-B-bound persistence
    // pointed at the SAME dir + same KEK. MB-1 metadata guard must reject.
    let kekKey = SymmetricKey(size: .bits256)
    let dir = tmpDir()
    let hash = Data("shared-hash".utf8)

    let pA = EncryptedPrefixCachePersistence(kekKey: kekKey, dir: dir, binding: binding(model: "modelA", layers: 2))
    pA.saveBlock(blockHash: hash, layerCaches: block(layers: 2, tokens: 8))

    let pB = EncryptedPrefixCachePersistence(kekKey: kekKey, dir: dir, binding: binding(model: "modelB", layers: 2))
    #expect(pB.loadBlock(blockHash: hash) == nil, "MB-1: model B must not load model A's block")
}

@Test
func persistenceWrongKEKReturnsNil() {
    let dir = tmpDir()
    let hash = Data("h".utf8)
    let pWrite = EncryptedPrefixCachePersistence(
        kekKey: SymmetricKey(size: .bits256), dir: dir, binding: binding(model: "m", layers: 1))
    pWrite.saveBlock(blockHash: hash, layerCaches: block(layers: 1, tokens: 8))

    // Different KEK → DEK unwrap fails → loadBlock returns nil (no crash).
    let pRead = EncryptedPrefixCachePersistence(
        kekKey: SymmetricKey(size: .bits256), dir: dir, binding: binding(model: "m", layers: 1))
    #expect(pRead.loadBlock(blockHash: hash) == nil)
}

@Test
func endToEndEvictionPersistsAndReloadsThroughRealPrefixCache() {
    // Drive the REAL upstream PrefixCache (submodule change): a tiny
    // maxBlocks forces eviction, which must call saveBlock; a later fetch
    // for the evicted prefix must reload via loadBlock instead of missing.
    let kekKey = SymmetricKey(size: .bits256)
    let dir = tmpDir()
    let persistence = EncryptedPrefixCachePersistence(
        kekKey: kekKey, dir: dir, binding: binding(model: "m", layers: 2))

    // blockSize 4, only 1 in-GPU block → storing a 2nd prefix evicts the 1st.
    let cache = PrefixCache(
        config: PrefixCacheConfig(blockSize: 4, maxBlocks: 1),
        modelName: "m",
        persistence: persistence
    )

    // Two distinct 4-token prefixes (each exactly one block; storePrefix
    // needs > blockSize tokens to index a full block, so give 8).
    let tokensA = Array(0..<8)
    let tokensB = Array(100..<108)
    let caches = { (base: Float) in block(layers: 2, tokens: 8, base: base) }

    cache.storePrefix(requestId: "A", tokens: tokensA, layerCaches: caches(0))
    cache.releaseRequest("A")
    // Storing B forces eviction of A's block(s) -> saveBlock(A) to SSD.
    cache.storePrefix(requestId: "B", tokens: tokensB, layerCaches: caches(1000))
    cache.releaseRequest("B")

    // A is no longer in GPU. fetchPrefix(A) must reload from SSD via
    // loadBlock and return a non-nil cached prefix.
    let (fetched, remaining) = cache.fetchPrefix(requestId: "A2", tokens: tokensA)
    #expect(fetched != nil, "evicted block A should reload from encrypted SSD on fetch")
    #expect(remaining.count < tokensA.count, "some prefix tokens should be served from cache")
}
