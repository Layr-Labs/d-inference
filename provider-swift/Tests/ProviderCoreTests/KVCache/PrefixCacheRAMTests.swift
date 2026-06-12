import Foundation
import Testing
@testable import MLX
@testable import MLXLMCommon
@testable import ProviderCore

// P1 unit tests for the RAM tier. No model, no SSD, no encryption —
// synthetic KVCacheSimple snapshots fed directly. Verifies:
//   * hit/miss + tokenCount round-trip
//   * MB-1: lookup is keyed by modelHash (no cross-model bleed)
//   * digest keying (different prefixes are distinct entries)
//   * SNAPSHOT INTEGRITY: a returned copy can be mutated without
//     corrupting the stored entry (the load-bearing copy()-on-get)
//   * LRU eviction by entry count
//   * eviction by byte budget
//   * clear(modelHash:) drops only that model

private let H = 1, D = 4

/// Build a KVCacheSimple holding `n` tokens, token t encoded as K=t,
/// V=t+100, shape [1,H,n,D].
private func simpleCache(tokens n: Int, base: Float = 0) -> KVCacheSimple {
    let c = KVCacheSimple()
    var kf: [Float] = []
    var vf: [Float] = []
    for t in 0..<n {
        for _ in 0..<(H * D) { kf.append(base + Float(t)) }
    }
    for t in 0..<n {
        for _ in 0..<(H * D) { vf.append(base + Float(t) + 100) }
    }
    let k = MLXArray(kf, [1, H, n, D])
    let v = MLXArray(vf, [1, H, n, D])
    _ = c.update(keys: k, values: v)
    eval(c.innerState())
    return c
}

private func digest(_ s: String) -> Data { Data(s.utf8) }

@Test
func ramHitAndMissRoundtrip() {
    let ram = PrefixCacheRAM()
    let key = PrefixCacheKey(modelHash: "modelA", digest: digest("sysprompt-1"))

    #expect(ram.get(key) == nil)  // miss
    ram.put(key, caches: [simpleCache(tokens: 8)], tokenCount: 8)

    let hit = ram.get(key)
    #expect(hit != nil)
    #expect(hit?.tokenCount == 8)
    #expect(hit?.caches.count == 1)
    #expect(hit?.caches[0].offset == 8)

    let stats = ram.snapshotStats()
    #expect(stats.hits == 1)
    #expect(stats.misses == 1)
    #expect(stats.inserts == 1)
    #expect(stats.entries == 1)
}

@Test
func ramIsKeyedByModelHash_MB1() {
    // Same digest, different model → must be a miss for the other model.
    let ram = PrefixCacheRAM()
    let dg = digest("shared-prefix")
    ram.put(modelHash: "modelA", digest: dg, caches: [simpleCache(tokens: 4)], tokenCount: 4)

    #expect(ram.get(modelHash: "modelA", digest: dg) != nil)
    #expect(ram.get(modelHash: "modelB", digest: dg) == nil,
            "MB-1: model B must not get model A's entry")
}

@Test
func ramDistinctDigestsAreDistinctEntries() {
    let ram = PrefixCacheRAM()
    ram.put(modelHash: "m", digest: digest("p1"), caches: [simpleCache(tokens: 4)], tokenCount: 4)
    ram.put(modelHash: "m", digest: digest("p2"), caches: [simpleCache(tokens: 6)], tokenCount: 6)

    #expect(ram.count == 2)
    #expect(ram.get(modelHash: "m", digest: digest("p1"))?.tokenCount == 4)
    #expect(ram.get(modelHash: "m", digest: digest("p2"))?.tokenCount == 6)
}

@Test
func getReturnsIndependentCopy() {
    // The load-bearing invariant: mutating a returned copy must NOT
    // corrupt the stored snapshot. Get the cache, decode more tokens
    // into the copy, then get again and confirm the second copy still
    // reflects the original token count.
    let ram = PrefixCacheRAM()
    let key = PrefixCacheKey(modelHash: "m", digest: digest("p"))
    ram.put(key, caches: [simpleCache(tokens: 8)], tokenCount: 8)

    let first = ram.get(key)!
    #expect(first.caches[0].offset == 8)

    // Mutate the returned copy: append 5 more tokens.
    let extra = MLXArray(Array(repeating: Float(999), count: H * 5 * D), [1, H, 5, D])
    _ = first.caches[0].update(keys: extra, values: extra)
    eval(first.caches[0].innerState())
    #expect(first.caches[0].offset == 13)  // the copy grew

    // The stored snapshot must be untouched.
    let second = ram.get(key)!
    #expect(second.caches[0].offset == 8,
            "stored snapshot was corrupted by a consumer mutating its copy (offset \(second.caches[0].offset), want 8)")
}

@Test
func ramEvictsLRUByEntryCount() {
    let ram = PrefixCacheRAM(maxEntries: 2, maxBytes: 0)  // count bound only
    ram.put(modelHash: "m", digest: digest("a"), caches: [simpleCache(tokens: 2)], tokenCount: 2)
    ram.put(modelHash: "m", digest: digest("b"), caches: [simpleCache(tokens: 2)], tokenCount: 2)

    // Touch "a" so "b" becomes least-recently-used.
    _ = ram.get(modelHash: "m", digest: digest("a"))

    // Insert "c" → over the count bound → evict LRU ("b").
    ram.put(modelHash: "m", digest: digest("c"), caches: [simpleCache(tokens: 2)], tokenCount: 2)

    #expect(ram.count == 2)
    #expect(ram.get(modelHash: "m", digest: digest("a")) != nil, "recently-used 'a' should survive")
    #expect(ram.get(modelHash: "m", digest: digest("c")) != nil, "just-inserted 'c' should survive")
    #expect(ram.get(modelHash: "m", digest: digest("b")) == nil, "LRU 'b' should have been evicted")
    #expect(ram.snapshotStats().evictions == 1)
}

@Test
func ramEvictsByByteBudget() {
    // One 8-token cache: [1,1,8,4] float32 keys + values = 2*8*4*4 = 256 bytes.
    let oneBytes = PrefixCacheRAM.byteSize(of: [simpleCache(tokens: 8)])
    #expect(oneBytes > 0)

    // Budget that fits ~1.5 entries → second insert evicts the first.
    let ram = PrefixCacheRAM(maxEntries: 0, maxBytes: oneBytes + oneBytes / 2)
    ram.put(modelHash: "m", digest: digest("a"), caches: [simpleCache(tokens: 8)], tokenCount: 8)
    ram.put(modelHash: "m", digest: digest("b"), caches: [simpleCache(tokens: 8)], tokenCount: 8)

    #expect(ram.count == 1, "byte budget should hold only one entry")
    #expect(ram.byteSize <= oneBytes + oneBytes / 2)
    #expect(ram.get(modelHash: "m", digest: digest("b")) != nil, "newest should survive")
}

@Test
func ramRejectsEntryLargerThanByteBudget() {
    // PCR-2: an entry bigger than maxBytes must be refused up front
    // (not stored-then-self-evicted into a silent no-op).
    let oneBytes = PrefixCacheRAM.byteSize(of: [simpleCache(tokens: 8)])
    let ram = PrefixCacheRAM(maxEntries: 0, maxBytes: oneBytes / 2)  // too small for any entry

    let stored = ram.put(modelHash: "m", digest: digest("p"), caches: [simpleCache(tokens: 8)], tokenCount: 8)
    #expect(stored == false, "oversized entry should be refused")
    #expect(ram.count == 0)
    #expect(ram.byteSize == 0, "refused entry must not leak bytes into accounting")
    #expect(ram.get(modelHash: "m", digest: digest("p")) == nil)
    #expect(ram.snapshotStats().rejects == 1)
    #expect(ram.snapshotStats().inserts == 0)
}

@Test
func ramPeekAndFlushCandidatesDoNotCountAsHits() {
    let ram = PrefixCacheRAM()
    let key = PrefixCacheKey(modelHash: "m", digest: digest("p"))
    let caches = [simpleCache(tokens: 8)]
    let bytes = PrefixCacheRAM.byteSize(of: caches)
    ram.put(key, caches: caches, tokenCount: 8)

    let info = ram.peek(key)
    #expect(info?.tokenCount == 8)
    #expect(info?.bytes == bytes)
    #expect(ram.snapshotStats().hits == 0, "peek must not materialize or count as a lookup hit")

    let candidates = ram.flushCandidates(modelHash: "m")
    #expect(candidates.count == 1)
    #expect(candidates[0].key == key)
    #expect(candidates[0].bytes == bytes)
    #expect(ram.snapshotStats().hits == 0, "flush candidate enumeration must not copy or count as hits")
}

@Test
func ramClearByModelDropsOnlyThatModel() {
    let ram = PrefixCacheRAM()
    ram.put(modelHash: "A", digest: digest("p"), caches: [simpleCache(tokens: 2)], tokenCount: 2)
    ram.put(modelHash: "A", digest: digest("q"), caches: [simpleCache(tokens: 2)], tokenCount: 2)
    ram.put(modelHash: "B", digest: digest("p"), caches: [simpleCache(tokens: 2)], tokenCount: 2)

    let removed = ram.clear(modelHash: "A")
    #expect(removed == 2)
    #expect(ram.count == 1)
    #expect(ram.get(modelHash: "B", digest: digest("p")) != nil)
    #expect(ram.get(modelHash: "A", digest: digest("p")) == nil)
}

@Test
func ramPutReplacesExistingKeyWithoutLeakingBytes() {
    let ram = PrefixCacheRAM()
    let key = PrefixCacheKey(modelHash: "m", digest: digest("p"))
    ram.put(key, caches: [simpleCache(tokens: 4)], tokenCount: 4)

    // Replace the snapshot for the same key.
    ram.put(key, caches: [simpleCache(tokens: 8)], tokenCount: 8)
    #expect(ram.count == 1, "replacing a key must not create a second entry")
    // No leak: replacing drops the old entry's bytes, so the total equals
    // exactly one current entry's size — not the sum of both puts. (Byte
    // accounting is physical/innerState-based; KVCacheSimple over-allocates
    // in step chunks, so the 4- and 8-token buffers happen to be equal —
    // the point here is that nothing accumulates across the replacement.)
    #expect(ram.byteSize == PrefixCacheRAM.byteSize(of: [simpleCache(tokens: 8)]),
            "replacement must not leak the prior entry's bytes")
    #expect(ram.get(key)?.tokenCount == 8)
}

@Test
func entriesForFlushReturnsCopiesPerModel() {
    let ram = PrefixCacheRAM()
    ram.put(modelHash: "A", digest: digest("p"), caches: [simpleCache(tokens: 4)], tokenCount: 4)
    ram.put(modelHash: "B", digest: digest("q"), caches: [simpleCache(tokens: 6)], tokenCount: 6)

    let flush = ram.entriesForFlush(modelHash: "A")
    #expect(flush.count == 1)
    #expect(flush[0].tokenCount == 4)
    #expect(flush[0].key.modelHash == "A")
    // entriesForFlush does not remove.
    #expect(ram.count == 2)
}

@Test
func entryForFlushReturnsOneIndependentCopy() {
    let ram = PrefixCacheRAM()
    ram.put(modelHash: "A", digest: digest("p"), caches: [simpleCache(tokens: 4)], tokenCount: 4)
    ram.put(modelHash: "A", digest: digest("q"), caches: [simpleCache(tokens: 6)], tokenCount: 6)
    ram.put(modelHash: "B", digest: digest("p"), caches: [simpleCache(tokens: 8)], tokenCount: 8)

    let flush = ram.entryForFlush(modelHash: "A", digest: digest("q"))
    #expect(flush != nil)
    #expect(flush?.key.modelHash == "A")
    #expect(flush?.key.digest == digest("q"))
    #expect(flush?.tokenCount == 6)
    #expect(flush?.caches.count == 1)
    #expect(flush?.caches[0].offset == 6)

    let extra = MLXArray(Array(repeating: Float(999), count: H * 3 * D), [1, H, 3, D])
    _ = flush!.caches[0].update(keys: extra, values: extra)
    eval(flush!.caches[0].innerState())
    #expect(flush!.caches[0].offset == 9)

    #expect(ram.get(modelHash: "A", digest: digest("q"))?.caches[0].offset == 6,
            "single-entry flush snapshot must be an independent copy")
    #expect(ram.entryForFlush(modelHash: "A", digest: digest("missing")) == nil)
    #expect(ram.count == 3, "entryForFlush snapshots without removing entries")
}
