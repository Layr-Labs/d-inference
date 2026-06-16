import CryptoKit
import Foundation
import Testing
@testable import MLX
@testable import MLXLMCommon
@testable import ProviderCore

// Phase 4: KV cache must be purged from RAM and SSD on every unload (restart
// warmth is OFF), and stale on-disk KV from a prior crash must be swept at
// startup. These cover the new GlobalDiskAccountant startup sweep + the
// engine/checkpoint tier per-model dir purge.

private func tmpKVRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("dbkv-purge-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeFakeModelDir(_ kvRoot: URL, _ modelKey: String) {
    let dir = kvRoot.appendingPathComponent(modelKey, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? Data(repeating: 7, count: 4096).write(
        to: dir.appendingPathComponent("stale.\(EncryptedKVStore.fileExtension)"))
}

// MARK: - Startup sweep

@Test func startupSweepWipesStaleKVDirs() {
    let kvRoot = tmpKVRoot()
    defer { try? FileManager.default.removeItem(at: kvRoot) }
    // Two stale per-model dirs left by a prior crash.
    makeFakeModelDir(kvRoot, "modelA")
    makeFakeModelDir(kvRoot, "modelB")
    #expect((try? FileManager.default.contentsOfDirectory(atPath: kvRoot.path))?.count == 2)

    // Constructing the accountant with sweepOnInit wipes them before any load.
    _ = GlobalDiskAccountant(kvRoot: kvRoot, sweepOnInit: true)

    let remaining = (try? FileManager.default.contentsOfDirectory(atPath: kvRoot.path)) ?? []
    #expect(remaining.isEmpty, "startup sweep must remove every stale per-model dir")
    // Root still exists (re-created), so subsequent loads can write.
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: kvRoot.path, isDirectory: &isDir) && isDir.boolValue)
}

@Test func defaultInitDoesNotSweep() {
    let kvRoot = tmpKVRoot()
    defer { try? FileManager.default.removeItem(at: kvRoot) }
    makeFakeModelDir(kvRoot, "keep")
    // Default (sweepOnInit: false) must preserve dirs — tests/other callers rely
    // on it not wiping their fixtures.
    _ = GlobalDiskAccountant(kvRoot: kvRoot)
    #expect((try? FileManager.default.contentsOfDirectory(atPath: kvRoot.path))?.count == 1)
}

// MARK: - Engine-tier purge

@Test func engineTierPurgeDirDeletesDirectoryAndLatchesClosed() throws {
    let kvRoot = tmpKVRoot()
    defer { try? FileManager.default.removeItem(at: kvRoot) }
    let modelKey = "purge-engine"
    let dir = kvRoot.appendingPathComponent(modelKey, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 2048).write(
        to: dir.appendingPathComponent("blk.\(EncryptedKVStore.fileExtension)"))

    let binding = PrefixCacheModelBinding(
        modelHash: "sha256:engpurge", modelDtype: "float32", modelArch: "Llama",
        vocabSize: 1000, numLayers: 2, kvHeads: 2, headDim: 4)
    let persistence = EncryptedPrefixCachePersistence(
        kekKey: SymmetricKey(size: .bits256), dir: dir, binding: binding,
        accountant: nil, modelKey: modelKey)

    #expect(FileManager.default.fileExists(atPath: dir.path))
    persistence.purgeDir()
    #expect(!FileManager.default.fileExists(atPath: dir.path),
        "purgeDir must remove the kv/<modelKey> directory")
    // Idempotent — a second call (or a no-op when the other tier already deleted
    // the shared dir) must not throw.
    persistence.purgeDir()
}

@Test func engineTierSaveBlockRacingPurgeLeavesNoFile() throws {
    // Regression for the Phase 4 review bug: saveBlock passes its entry `closed`
    // guard, then purgeDir() runs mid-write (EngineCore.stop doesn't fence the
    // engine queue) and removeItem deletes the dir; writeSync's atomic writer
    // RE-CREATES the dir and lands the file. Without the post-write `closed`
    // re-check, that block survives the unload (warmth is off → never reclaimed).
    let kvRoot = tmpKVRoot()
    defer { try? FileManager.default.removeItem(at: kvRoot) }
    let modelKey = "race-engine"
    let dir = kvRoot.appendingPathComponent(modelKey, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let binding = PrefixCacheModelBinding(
        modelHash: "sha256:racemodel", modelDtype: "float32", modelArch: "Llama",
        vocabSize: 1000, numLayers: 2, kvHeads: 2, headDim: 4)
    let persistence = EncryptedPrefixCachePersistence(
        kekKey: SymmetricKey(size: .bits256), dir: dir, binding: binding,
        accountant: nil, modelKey: modelKey)

    // The hook fires BEFORE writeSync: simulate the unload purge (closed +
    // removeItem(dir)) landing first, so writeSync then re-creates the dir and
    // lands the file — the exact production race the post-write bail must catch.
    persistence._beforeWriteHookForTest = { persistence.purgeDir() }

    let block = (0..<2).map { l -> KVCacheSimple in
        let c = KVCacheSimple()
        let n = 2 * 8 * 4
        let k = MLXArray((0..<n).map { Float($0 + l) }, [1, 2, 8, 4])
        let v = MLXArray((0..<n).map { Float($0 + l) + 9 }, [1, 2, 8, 4])
        _ = c.update(keys: k, values: v); eval(c.innerState())
        return c
    }
    persistence.saveBlock(blockHash: Data([1, 2, 3, 4]), layerCaches: block)

    // The post-write bail must have deleted the file the racing write landed, so
    // NO .darkbloom-kv block survives in the purged dir.
    let survivors = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
        .filter { $0.hasSuffix(EncryptedKVStore.fileExtension) } ?? []
    #expect(survivors.isEmpty,
        "a saveBlock racing purgeDir must leave no KV block behind (post-write closed bail)")
}

// MARK: - Checkpoint-tier purge

@Test func checkpointTierPurgeOnUnloadDeletesDirectory() async throws {
    let kvRoot = tmpKVRoot()
    defer { try? FileManager.default.removeItem(at: kvRoot) }
    let modelKey = "purge-ckpt"
    let cacheDir = kvRoot.appendingPathComponent(modelKey, isDirectory: true)
    try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    try Data(repeating: 2, count: 2048).write(
        to: cacheDir.appendingPathComponent("ckpt.\(EncryptedKVStore.fileExtension)"))

    let binding = PrefixCacheModelBinding(
        modelHash: "sha256:ckptpurge", modelDtype: "float32", modelArch: "Llama",
        vocabSize: 1000, numLayers: 4, kvHeads: 2, headDim: 4)
    let mgr = PrefixCacheManager(
        binding: binding,
        ram: PrefixCacheRAM(),
        index: PrefixCacheIndex(fileURL: cacheDir.appendingPathComponent("index.json")),
        kek: KVCacheKEK(wrapper: InMemoryKeyWrappingService(),
                        storage: InMemoryWrappedKEKStorage(identifier: UUID().uuidString)),
        cacheDir: cacheDir,
        ssdEnabled: true,
        modelKey: modelKey)

    #expect(FileManager.default.fileExists(atPath: cacheDir.path))
    await mgr.purgeOnUnload()
    #expect(!FileManager.default.fileExists(atPath: cacheDir.path),
        "purgeOnUnload must remove the kv/<modelKey> directory (no restart warmth)")
}
