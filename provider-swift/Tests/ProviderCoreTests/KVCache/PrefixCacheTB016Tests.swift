import Foundation
import Testing
@testable import MLX
@testable import MLXLMCommon
@testable import ProviderCore

// TB-016 tests: boundary-ladder lift (A), RAM-first admission (B),
// benefit-per-byte eviction (C).

// MARK: - Sub-feature A: Ladder lift

@Test
func ladderWithinWindowByteIdenticalWhenProvenFalse() {
    // When pastWindowProven=false, the new overload MUST return the same
    // boundaries as the old checkpoints(forSlidingWindow:).
    let window = 1024
    let old = PrefixDigest.checkpoints(forSlidingWindow: window)
    let new = PrefixDigest.checkpoints(
        forSlidingWindow: window,
        maxContext: 131072,
        pastWindowProven: false
    )
    #expect(old == new, "proven=false must keep existing ladder")
}

@Test
func ladderWithinWindowByteIdenticalWhenMaxContextZero() {
    // When maxContext=0, the new overload MUST return the same boundaries.
    let window = 1024
    let old = PrefixDigest.checkpoints(forSlidingWindow: window)
    let new = PrefixDigest.checkpoints(
        forSlidingWindow: window,
        maxContext: 0,
        pastWindowProven: true
    )
    #expect(old == new, "maxContext=0 must keep existing ladder")
}

@Test
func ladderLiftedForGemmaProvenTrue() {
    // Gemma: window=1024, maxContext=131072, proven=true
    // In-window ladder for 1024: [256, 512, 1024]
    // Coarse tail [2048, 4096, 8192, 16384, 32768] all ≤ 131072
    let boundaries = PrefixDigest.checkpoints(
        forSlidingWindow: 1024,
        maxContext: 131072,
        pastWindowProven: true
    )
    // Must include the fine in-window ladder PLUS coarse tail capped at 32768.
    #expect(boundaries.contains(256))
    #expect(boundaries.contains(512))
    #expect(boundaries.contains(1024))
    #expect(boundaries.contains(2048))
    #expect(boundaries.contains(4096))
    #expect(boundaries.contains(8192))
    #expect(boundaries.contains(16384))
    #expect(boundaries.contains(32768))
    // Must NOT include anything beyond the 32768 ceiling.
    #expect(!boundaries.contains(65536))
    #expect(boundaries == boundaries.sorted(), "must be sorted")
}

@Test
func ladderCappedAtMaxContext() {
    // When maxContext=10000, tail stops at 8192 (the last boundary ≤ 10000).
    let boundaries = PrefixDigest.checkpoints(
        forSlidingWindow: 512,
        maxContext: 10000,
        pastWindowProven: true
    )
    #expect(boundaries.contains(8192))
    #expect(!boundaries.contains(16384), "16384 > maxContext=10000")
}

@Test
func ladderUnchangedForGptOssUnproven() {
    // GPT-OSS: window=128, proven=false (genuinely discards).
    // Old ladder: [64, 128]. New overload with proven=false must match.
    let old = PrefixDigest.checkpoints(forSlidingWindow: 128)
    let new = PrefixDigest.checkpoints(
        forSlidingWindow: 128,
        maxContext: 8192,
        pastWindowProven: false
    )
    #expect(old == new)
    #expect(old == [64, 128])
}

@Test
func pastWindowProvenGate() {
    // isProven(arch:) is true for the PROVEN families (Gemma + GPT-OSS, both
    // bit-exact-verified past their window on real weights), case-insensitive
    // substring match. Everything else is false (safe default).
    #expect(PrefixCachePastWindow.isProven(arch: "gemma"))
    #expect(PrefixCachePastWindow.isProven(arch: "Gemma"))
    #expect(PrefixCachePastWindow.isProven(arch: "gemma2"))
    #expect(PrefixCachePastWindow.isProven(arch: "GEMMA"))
    #expect(PrefixCachePastWindow.isProven(arch: "mlx-community/gemma-4-2b-instruct"))
    // GPT-OSS now proven (gptOssRestoreMatchesColdPastWindow, M5).
    #expect(PrefixCachePastWindow.isProven(arch: "gpt-oss"))
    #expect(PrefixCachePastWindow.isProven(arch: "mlx-community/gpt-oss-20b-MXFP4-Q8"))
    #expect(PrefixCachePastWindow.isProven(arch: "GPT-OSS"))
    // Unproven families keep the within-window ladder.
    #expect(!PrefixCachePastWindow.isProven(arch: "gpt2"))   // not gpt-oss
    #expect(!PrefixCachePastWindow.isProven(arch: "qwen"))
    #expect(!PrefixCachePastWindow.isProven(arch: "llama"))
    #expect(!PrefixCachePastWindow.isProven(arch: "unknown"))
}

// MARK: - Sub-feature B: RAM-first admission

private let H = 2, D = 4

private func attnCaches(layers: Int, tokens: Int) -> [any KVCache] {
    (0..<layers).map { l in
        let c = KVCacheSimple()
        let k = MLXArray((0..<(H * tokens * D)).map { Float($0 + l * 7) }, [1, H, tokens, D])
        let v = MLXArray((0..<(H * tokens * D)).map { Float($0 + l * 7) + 100 }, [1, H, tokens, D])
        _ = c.update(keys: k, values: v)
        eval(c.innerState())
        return c
    }
}

private func tmpDir() -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("dbkv-tb016-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func binding(model: String, layers: Int = 2) -> PrefixCacheModelBinding {
    // Use a proper sha256: prefixed hash so modelDirComponent works correctly.
    let hash = "sha256:\(model)"
    return PrefixCacheModelBinding(
        modelHash: hash, modelDtype: "float32", modelArch: "Llama", vocabSize: 1000,
        numLayers: layers, kvHeads: H, headDim: D
    )
}

private func makeManager(
    model: String,
    ssd: Bool,
    minPersist: Int = 0,
    dir: URL? = nil,
    diskBudget: Int = 0,
    now: @escaping @Sendable () -> Int64 = { 1000 }
) -> (PrefixCacheManager, URL) {
    let cacheDir = dir ?? tmpDir()
    let mgr = PrefixCacheManager(
        binding: binding(model: model),
        ram: PrefixCacheRAM(),
        index: ssd ? PrefixCacheIndex(fileURL: cacheDir.appendingPathComponent("index.json")) : nil,
        kek: ssd ? KVCacheKEK(wrapper: InMemoryKeyWrappingService(),
                              storage: InMemoryWrappedKEKStorage(identifier: UUID().uuidString)) : nil,
        cacheDir: ssd ? cacheDir : nil,
        ssdEnabled: ssd,
        boundaries: [4, 8],
        diskBudgetBytes: diskBudget,
        minPersistTokens: minPersist,
        now: now,
        modelKey: "test-model"
    )
    return (mgr, cacheDir)
}

private func prompt(_ n: Int) -> [Int] { Array(0..<n) }

/// Poll for a file to appear (a detached promotion Task writes it
/// off-actor). Returns true as soon as it exists, false on timeout.
private func waitForFile(at url: URL, timeout: Duration) async -> Bool {
    let deadlineSteps = max(1, Int(timeout / .milliseconds(20)))
    for _ in 0..<deadlineSteps {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return FileManager.default.fileExists(atPath: url.path)
}

@Test
func storeIsRamOnlyNoEagerFlush() async {
    // TB-016 sub-feature B: store() (which the capture hook calls) is
    // RAM-only and must NOT create an SSD file — persistence is deferred to
    // 2nd-use promotion / explicit flush. This guards the store() contract
    // the capture closure relies on. (The capture *closure* itself — that it
    // calls only store() and not flushToSSD — needs a loaded engine and is
    // covered by the model-gated live tests; the inverse promotion behavior
    // is guarded model-free by secondLookupPromotesToSSD below.)
    let modelHash = "abcd1234abcd"
    let (mgr, dir) = makeManager(model: modelHash, ssd: true)
    let tokens = prompt(10)
    await mgr.store(tokens: tokens, checkpointLength: 8, caches: SendableKVCaches(attnCaches(layers: 2, tokens: 8)))

    // File must NOT exist (capture is RAM-only).
    let digest = PrefixDigest.digest(tokens: tokens, length: 8)
    // modelDirComponent = first 12 chars after stripping "sha256:"
    let fileURL = dir.appendingPathComponent("\(modelHash)/\(digest.dbkvHexString).darkbloom-kv")
    #expect(!FileManager.default.fileExists(atPath: fileURL.path),
            "Capture must NOT eager-flush to SSD")

    // RAM hit must still work.
    let hit = await mgr.lookup(tokens: tokens)
    #expect(hit?.tier == .ram)
    #expect(hit?.tokenCount == 8)
}

@Test
func secondLookupPromotesToSSD() async throws {
    // TB-016 sub-feature B: a 2nd lookup of a >=minPersistTokens RAM-resident
    // prefix must promote it to SSD (file + index entry appear).
    let modelHash = "abcd1234abcd"
    let (mgr, dir) = makeManager(model: modelHash, ssd: true, minPersist: 4)
    let tokens = prompt(10)

    // First store (RAM-only).
    await mgr.store(tokens: tokens, checkpointLength: 8, caches: SendableKVCaches(attnCaches(layers: 2, tokens: 8)))

    // First lookup (RAM hit, triggers detached promotion).
    let hit1 = await mgr.lookup(tokens: tokens)
    #expect(hit1?.tier == .ram)

    // The promotion runs in a detached Task; poll for the file rather than a
    // fixed sleep (robust on a loaded CI box).
    let digest = PrefixDigest.digest(tokens: tokens, length: 8)
    let fileURL = dir.appendingPathComponent("\(modelHash)/\(digest.dbkvHexString).darkbloom-kv")
    let appeared = await waitForFile(at: fileURL, timeout: .seconds(10))
    #expect(appeared, "2nd-use promotion must create SSD file")

    // Clear RAM and verify the next lookup hits SSD. The promotion is a
    // detached Task that writes the file THEN records the index entry; under
    // parallel test load the index.record can lag the file by a beat, so poll
    // the actual SSD hit (needs file AND index entry) rather than assuming the
    // first post-clear lookup wins the race.
    await mgr.clearRAM()
    var hit2 = await mgr.lookup(tokens: tokens)
    var waited = 0
    while hit2?.tier != .ssd, waited < 500 {
        try? await Task.sleep(for: .milliseconds(20))
        waited += 1
        await mgr.clearRAM()  // a missed lookup may have promoted RAM; keep RAM empty
        hit2 = await mgr.lookup(tokens: tokens)
    }
    #expect(hit2?.tier == .ssd)
    #expect(hit2?.tokenCount == 8)
}

@Test
func subThresholdPrefixNotPromoted() async throws {
    // TB-016 sub-feature B: a < minPersistTokens prefix must NOT be
    // promoted on 2nd use.
    let modelHash = "abcd1234abcd"
    let (mgr, dir) = makeManager(model: modelHash, ssd: true, minPersist: 16)
    let tokens = prompt(10)

    // Store a short checkpoint (8 tokens < 16 threshold).
    await mgr.store(tokens: tokens, checkpointLength: 8, caches: SendableKVCaches(attnCaches(layers: 2, tokens: 8)))

    // Lookup twice.
    _ = await mgr.lookup(tokens: tokens)
    _ = await mgr.lookup(tokens: tokens)

    try await Task.sleep(for: .milliseconds(100))

    // File must NOT exist (below threshold).
    let digest = PrefixDigest.digest(tokens: tokens, length: 8)
    let fileURL = dir.appendingPathComponent("\(modelHash)/\(digest.dbkvHexString).darkbloom-kv")
    #expect(!FileManager.default.fileExists(atPath: fileURL.path),
            "Sub-threshold prefix must NOT promote")
}

@Test
func bulkFlushSkipsSubThresholdEntries() async {
    // TB-016 sub-feature B: flushToSSD must skip entries with
    // tokenCount < minPersistTokens (defensive guard so a stray bulk-flush
    // caller can't persist one-offs).
    let modelHash = "abcd1234abcd"
    let (mgr, _) = makeManager(model: modelHash, ssd: true, minPersist: 8)
    let tokens = prompt(10)

    // Store a short checkpoint (4 tokens < 8 threshold).
    await mgr.store(tokens: tokens, checkpointLength: 4, caches: SendableKVCaches(attnCaches(layers: 2, tokens: 4)))

    // Explicit bulk flush.
    let written = await mgr.flushToSSD()
    #expect(written == 0, "Sub-threshold entries must be skipped by bulk flush")
}

// MARK: - Sub-feature C: Benefit-per-byte eviction

@Test
func benefitScoreDivByZeroGuard() {
    // TB-016 sub-feature C: benefitScore must guard against fileBytes=0.
    let e = PrefixIndexEntry(
        modelHash: "m", digestHex: "abc", tokenCount: 100,
        relativePath: "m/x.dbkv", fileBytes: 0,
        createdAt: 1000, lastHitAt: 1000, hitCount: 5
    )
    let score = PrefixCacheIndex.benefitScore(
        e, now: 1100, prefillCostPerToken: 1.0, halfLifeSeconds: 86400
    )
    // Must not crash; score should be finite.
    #expect(score.isFinite)
    #expect(score > 0, "fileBytes guarded to max(1, ...), so score > 0")
}

@Test
func benefitScoreOrderingHotBeatsStale() {
    // A small, recently-hit, frequently-accessed entry should outscore a
    // large, stale, rarely-accessed entry (LOWEST score evicts first).
    let hot = PrefixIndexEntry(
        modelHash: "m", digestHex: "h", tokenCount: 1000,
        relativePath: "m/h.dbkv", fileBytes: 10_000,
        createdAt: 1000, lastHitAt: 2000, hitCount: 10
    )
    let stale = PrefixIndexEntry(
        modelHash: "m", digestHex: "s", tokenCount: 1000,
        relativePath: "m/s.dbkv", fileBytes: 100_000,
        createdAt: 1000, lastHitAt: 1100, hitCount: 1
    )
    let now: Int64 = 2100
    let scoreHot = PrefixCacheIndex.benefitScore(
        hot, now: now, prefillCostPerToken: 1.0, halfLifeSeconds: 86400
    )
    let scoreStale = PrefixCacheIndex.benefitScore(
        stale, now: now, prefillCostPerToken: 1.0, halfLifeSeconds: 86400
    )
    #expect(scoreHot > scoreStale, "Hot entry must score higher than stale")
}

@Test
func evictionOrderByScoreAscending() {
    // TB-016 sub-feature C: entriesByScoreAscending must sort entries by
    // score (LOWEST first), not by lastHitAt. Verify the ordering directly.
    let idx = PrefixCacheIndex(fileURL: tmpDir().appendingPathComponent("test.json"))

    // Entry A: old (lastHitAt=1000), few hits (1), large (100k), low score.
    let eA = PrefixIndexEntry(
        modelHash: "m", digestHex: "aaa", tokenCount: 1000,
        relativePath: "m/a.dbkv", fileBytes: 100_000,
        createdAt: 1000, lastHitAt: 1000, hitCount: 1
    )

    // Entry B: recent (lastHitAt=2000), many hits (10), small (10k), high score.
    let eB = PrefixIndexEntry(
        modelHash: "m", digestHex: "bbb", tokenCount: 1000,
        relativePath: "m/b.dbkv", fileBytes: 10_000,
        createdAt: 1000, lastHitAt: 2000, hitCount: 10
    )

    idx.record(eA)
    idx.record(eB)

    // Fetch by score ascending (LOWEST score first).
    let ordered = idx.entriesByScoreAscending(
        modelHash: "m", now: 2100,
        prefillCostPerToken: 1.0, halfLifeSeconds: 86400
    )

    // Entry A (low score) must come FIRST; entry B (high score) LAST.
    #expect(ordered.count == 2)
    #expect(ordered[0].digestHex == "aaa", "Lowest score (A) must be first")
    #expect(ordered[1].digestHex == "bbb", "Highest score (B) must be last")

    // Sanity-check: LRU order would be OPPOSITE (A evicted first by time).
    let lru = idx.entriesLRUFirst(modelHash: "m")
    #expect(lru[0].digestHex == "aaa", "LRU would also evict A first by lastHitAt")
    // (In this case both methods agree, but the scoring uses benefit/bytes.)
}

@Test
func freshPromotedEntryScoresHigher() {
    // TB-016 sub-feature C: a freshly-promoted entry (lastHitAt=now)
    // must score higher (recency≈1) than a stale entry. Verify scoring directly.
    let fresh = PrefixIndexEntry(
        modelHash: "m", digestHex: "fresh", tokenCount: 1000,
        relativePath: "m/f.dbkv", fileBytes: 50_000,
        createdAt: 1000, lastHitAt: 2000, hitCount: 1  // just promoted
    )
    let stale = PrefixIndexEntry(
        modelHash: "m", digestHex: "stale", tokenCount: 1000,
        relativePath: "m/s.dbkv", fileBytes: 50_000,
        createdAt: 1000, lastHitAt: 1000, hitCount: 1  // old
    )

    let now: Int64 = 2000
    let scoreFresh = PrefixCacheIndex.benefitScore(
        fresh, now: now, prefillCostPerToken: 1.0, halfLifeSeconds: 86400
    )
    let scoreStale = PrefixCacheIndex.benefitScore(
        stale, now: now, prefillCostPerToken: 1.0, halfLifeSeconds: 86400
    )

    #expect(scoreFresh > scoreStale,
            "Fresh entry (recency≈1) must score higher than stale")
}
