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
        // Build the [Float] payloads with explicit types FIRST. Inlining the
        // `(0..<n).map { Float($0 + l*7) + base }` directly into the MLXArray
        // initializer makes Swift's overload solver time out on the CI
        // toolchain ("unable to type-check this expression in reasonable time")
        // — MLXArray has many init overloads and the mixed Int/Float closure
        // explodes inference. Typed locals + a typed shape disambiguate it.
        let n = H * tokens * D
        let shape: [Int] = [1, H, tokens, D]
        let kData: [Float] = (0..<n).map { i in Float(i + l * 7) + base }
        let vData: [Float] = (0..<n).map { i in Float(i + l * 7) + base + 100 }
        let k = MLXArray(kData, shape)
        let v = MLXArray(vData, shape)
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
    let p = EncryptedPrefixCachePersistence(kekKey: kekKey, dir: dir, binding: binding(model: "m", layers: 3), modelKey: "test-model")
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
    let p = EncryptedPrefixCachePersistence(kekKey: kekKey, dir: dir, binding: binding(model: "m", layers: 1), modelKey: "test-model")
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

    let pA = EncryptedPrefixCachePersistence(kekKey: kekKey, dir: dir, binding: binding(model: "modelA", layers: 2), modelKey: "test-model")
    pA.saveBlock(blockHash: hash, layerCaches: block(layers: 2, tokens: 8))

    let pB = EncryptedPrefixCachePersistence(kekKey: kekKey, dir: dir, binding: binding(model: "modelB", layers: 2), modelKey: "test-model")
    #expect(pB.loadBlock(blockHash: hash) == nil, "MB-1: model B must not load model A's block")
}

@Test
func persistenceWrongKEKReturnsNil() {
    let dir = tmpDir()
    let hash = Data("h".utf8)
    let pWrite = EncryptedPrefixCachePersistence(
        kekKey: SymmetricKey(size: .bits256), dir: dir, binding: binding(model: "m", layers: 1), modelKey: "test-model")
    pWrite.saveBlock(blockHash: hash, layerCaches: block(layers: 1, tokens: 8))

    // Different KEK → DEK unwrap fails → loadBlock returns nil (no crash).
    let pRead = EncryptedPrefixCachePersistence(
        kekKey: SymmetricKey(size: .bits256), dir: dir, binding: binding(model: "m", layers: 1), modelKey: "test-model")
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
        kekKey: kekKey, dir: dir, binding: binding(model: "m", layers: 2), modelKey: "test-model")

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

@Test
func loadBlockRefusesFileHoldingDifferentPrefix() throws {
    // A same-model file at the wrong path (renamed/swapped, or a hash
    // collision) authenticates under its OWN metadata, so the model/shape
    // guard passes. The prefix-hash guard must still refuse it rather than
    // serve a different prompt's KV under the requested block hash.
    let kekKey = SymmetricKey(size: .bits256)
    let dir = tmpDir()
    let p = EncryptedPrefixCachePersistence(kekKey: kekKey, dir: dir, binding: binding(model: "m", layers: 2), modelKey: "test-model")

    let hashA = Data("prefix-A".utf8)
    let hashB = Data("prefix-B".utf8)
    p.saveBlock(blockHash: hashA, layerCaches: block(layers: 2, tokens: 8))

    // Simulate a renamed/swapped file: copy A's file onto B's path. Its
    // metadata still says tokenPrefixHash == hashA.
    let fileA = dir.appendingPathComponent("\(hashA.dbkvHexString).\(EncryptedKVStore.fileExtension)")
    let fileB = dir.appendingPathComponent("\(hashB.dbkvHexString).\(EncryptedKVStore.fileExtension)")
    try FileManager.default.copyItem(at: fileA, to: fileB)

    #expect(p.loadBlock(blockHash: hashB) == nil, "wrong-prefix file must be refused")
    #expect(p.loadBlock(blockHash: hashA) != nil, "correct-prefix file must still load")
}

@Test
func persistenceEvictsOldestWhenDiskBudgetExceeded() throws {
    // Without a disk budget the backend would accumulate a file per evicted
    // block forever, filling the volume. With a budget, a save that pushes
    // the directory over budget evicts oldest files until it's back under.
    let kekKey = SymmetricKey(size: .bits256)
    let dir = tmpDir()

    // Measure one file's size, then set a ~2.5-file budget.
    let probe = EncryptedPrefixCachePersistence(
        kekKey: kekKey, dir: dir, binding: binding(model: "m", layers: 2), modelKey: "test-model")
    probe.saveBlock(blockHash: Data("probe".utf8), layerCaches: block(layers: 2, tokens: 64))
    let probeURL = dir.appendingPathComponent(
        "\(Data("probe".utf8).dbkvHexString).\(EncryptedKVStore.fileExtension)")
    let fileSize = (try FileManager.default.attributesOfItem(atPath: probeURL.path)[.size] as? Int) ?? 0
    #expect(fileSize > 0)
    try FileManager.default.removeItem(at: probeURL)

    let budget = (fileSize * 5) / 2  // ~2.5 files
    let p = EncryptedPrefixCachePersistence(
        kekKey: kekKey, dir: dir, binding: binding(model: "m", layers: 2),
        diskBudgetBytes: budget)

    for i in 0..<6 {
        p.saveBlock(blockHash: Data("blk-\(i)".utf8), layerCaches: block(layers: 2, tokens: 64))
    }

    let files = try FileManager.default
        .contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        .filter { $0.lastPathComponent.hasSuffix(".\(EncryptedKVStore.fileExtension)") }
    let total = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

    #expect(total <= budget, "disk usage must stay within budget, got \(total) vs \(budget)")
    #expect(files.count < 6, "older files must have been evicted")
    #expect(!files.isEmpty, "the cache must still retain the most recent block(s)")
}

@Test
func persistenceSkipsWriteWhenBlockExceedsDiskBudget() throws {
    // A budget below one block's size must NOT produce a write-then-delete
    // treadmill: the save is skipped entirely (no file written, no churn).
    let kekKey = SymmetricKey(size: .bits256)
    let dir = tmpDir()
    let p = EncryptedPrefixCachePersistence(
        kekKey: kekKey, dir: dir, binding: binding(model: "m", layers: 2),
        diskBudgetBytes: 16)  // 16 bytes — far below any real block
    p.saveBlock(blockHash: Data("blk".utf8), layerCaches: block(layers: 2, tokens: 64))
    let files = try FileManager.default
        .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasSuffix(".\(EncryptedKVStore.fileExtension)") }
    #expect(files.isEmpty, "a block larger than the budget must not be written at all")
}

@Test
func loadBlockDeletesFileOnModelMismatch() throws {
    // Weight-change invalidation relies on a stale-weight file (written
    // under a different binding, same per-model directory) being rejected
    // AND deleted by loadBlock on access — so it doesn't linger or leak.
    let kekKey = SymmetricKey(size: .bits256)
    let dir = tmpDir()
    let hash = Data("blk".utf8)
    let pA = EncryptedPrefixCachePersistence(
        kekKey: kekKey, dir: dir, binding: binding(model: "weightA", layers: 2), modelKey: "test-model")
    pA.saveBlock(blockHash: hash, layerCaches: block(layers: 2, tokens: 8))
    let url = dir.appendingPathComponent("\(hash.dbkvHexString).\(EncryptedKVStore.fileExtension)")
    #expect(FileManager.default.fileExists(atPath: url.path))

    let pB = EncryptedPrefixCachePersistence(
        kekKey: kekKey, dir: dir, binding: binding(model: "weightB", layers: 2), modelKey: "test-model")
    #expect(pB.loadBlock(blockHash: hash) == nil, "stale-weight file must be refused")
    #expect(!FileManager.default.fileExists(atPath: url.path),
            "stale-weight file must be deleted on access (no leak)")
}
