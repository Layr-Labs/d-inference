import CryptoKit
import Foundation
import Testing
@testable import MLX
@testable import MLXLMCommon
@testable import ProviderCore

// SYNTHETIC repro of the 2.4GB flushToSSD → written=0 bug. No model needed.
// Gated behind an env var so it doesn't run in normal CI (it allocates GBs).
//   DARKBLOOM_BIGKV_REPRO=1 swift test --filter BigKVFlushRepro

private func bigEnabled() -> Bool {
    ProcessInfo.processInfo.environment["DARKBLOOM_BIGKV_REPRO"] != nil
}

private func newKEK() -> KVCacheKEK {
    KVCacheKEK(
        wrapper: InMemoryKeyWrappingService(),
        storage: InMemoryWrappedKEKStorage(identifier: UUID().uuidString))
}

private func tmpURL() -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("dbkv-bigrepro-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent("blob.\(EncryptedKVStore.fileExtension)")
}

/// Direct EncryptedKVStore.write of a single chunk of `bytes` bytes.
/// Tells us whether the write path itself fails/throws above some size.
@Test(.enabled(if: bigEnabled()))
func bigSingleChunkWrite_2_2GB() async throws {
    let url = tmpURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let kek = newKEK()

    // 2.2 GB single chunk — under UInt32.max (4GB) but above Int32.max (2GB).
    let n = 2_200_000_000
    print("REPRO single-chunk: allocating \(n) bytes (\(String(format: "%.2f", Double(n)/1_073_741_824))GB)")
    let plaintext = Data(count: n)
    let meta = EncryptedKVStoreMetadata(
        modelHash: "m", modelDtype: "x", modelArch: "x", vocabSize: 0,
        numLayers: 1, kvHeads: 1, headDim: 1, tokenCount: 1,
        tokenPrefixHash: "deadbeef", kvCacheClass: "mixed",
        metaState: ["{}"], chunkPlaintextSizes: [n], createdAt: 1)
    do {
        try await EncryptedKVStore.write(to: url, metadata: meta, chunks: [plaintext], kek: kek)
        let sz = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        print("REPRO single-chunk: WROTE file size=\(sz ?? -1)")
        #expect((sz ?? 0) > n)
        // Read-back: confirm the >2GB file decrypts (mmap read + per-chunk GCM).
        let (_, chunks) = try await EncryptedKVStore.read(from: url, kek: kek)
        print("REPRO single-chunk: READ-BACK chunks=\(chunks.count) bytes0=\(chunks.first?.count ?? -1)")
        #expect(chunks.count == 1)
        #expect(chunks[0].count == n)
    } catch {
        print("REPRO single-chunk: THREW \(String(describing: error))")
        throw error
    }
}

/// Full flushToSSD with a ~2.4GB hybrid checkpoint built from hand-made
/// KVCacheSimple + RotatingKVCache layers — the exact path the live test hits.
@Test(.enabled(if: bigEnabled()))
func bigFlushToSSD_2_4GB() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dbkv-bigflush-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Build ~2.4GB of full-attention layers: 13 layers × [1,2,100000,512] bf16
    // ≈ 13 × 195MB × ... actually that's 2 arrays/layer. Use 6 layers to keep
    // ~2.4GB total: 6 layers × 2 arrays × 195MB ≈ 2.34GB.
    let L = 100_000
    let kvHeads = 2, headDim = 512
    let layers = 6
    func bigSimple() -> KVCacheSimple {
        let c = KVCacheSimple()
        // bf16 zeros, shape [1, kvHeads, L, headDim]
        let k = MLXArray.zeros([1, kvHeads, L, headDim], dtype: .bfloat16)
        let v = MLXArray.zeros([1, kvHeads, L, headDim], dtype: .bfloat16)
        c.state = [k, v]
        eval(c.innerState())
        return c
    }
    var caches: [any KVCache] = []
    for _ in 0..<layers { caches.append(bigSimple()) }
    let bytes = caches.reduce(0) { acc, c in acc + c.innerState().reduce(0) { $0 + $1.nbytes } }
    print("REPRO bigflush: checkpoint bytes = \(String(format: "%.2f", Double(bytes)/1_073_741_824))GB across \(layers) layers")

    let binding = PrefixCacheModelBinding(
        modelHash: "m", modelDtype: "bf16", modelArch: "x", vocabSize: 0,
        numLayers: layers, kvHeads: kvHeads, headDim: headDim)
    let mgr = PrefixCacheManager(
        binding: binding,
        ram: PrefixCacheRAM(),  // default 8GB byte budget
        index: PrefixCacheIndex(fileURL: dir.appendingPathComponent("index.json")),
        kek: newKEK(),
        cacheDir: dir, ssdEnabled: true, boundaries: [L], now: { 1000 },
        modelKey: "test-model")

    let tokens = Array(0..<(L + 4))
    let stored = await mgr.store(tokens: tokens, checkpointLength: L, caches: SendableKVCaches(caches))
    let ram = await mgr.ramTierStats()
    print("REPRO bigflush: store→\(stored) ram entries=\(ram.entries) bytes=\(ram.bytes) rejects=\(ram.rejects)")
    let t0 = Date()
    let written = await mgr.flushToSSD()
    let dt = Date().timeIntervalSince(t0)
    print("REPRO bigflush: written=\(written) flush=\(String(format: "%.2f", dt))s")
    #expect(written == 1, "the big checkpoint must flush (written=\(written))")
}
