import Foundation
import Testing
@testable import ProviderCore

// P2 unit tests for the JSON-backed prefix cache index.

private func tmpIndexURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dbkv-index-tests", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("\(UUID().uuidString).json")
}

private func entry(
    model: String, tokens: [Int], length: Int, path: String,
    bytes: Int = 1000, now: Int64 = 1_000
) -> PrefixIndexEntry {
    let dg = PrefixDigest.digest(tokens: tokens, length: length)
    return PrefixIndexEntry(
        modelHash: model, digestHex: dg.dbkvHexString, tokenCount: length,
        relativePath: path, fileBytes: bytes, createdAt: now, lastHitAt: now
    )
}

@Test
func indexRecordsAndFindsExactCheckpoint() {
    let idx = PrefixCacheIndex(fileURL: tmpIndexURL())
    let tokens = (0..<600).map { $0 }  // checkpoints 256, 512

    idx.record(entry(model: "m", tokens: tokens, length: 512, path: "m/x.dbkv"))

    // A prompt sharing the first 600 tokens finds the 512 checkpoint.
    let prompt = tokens + [42, 43]
    let hit = idx.findLongestCheckpoint(modelHash: "m", tokens: prompt)
    #expect(hit?.tokenCount == 512)
    #expect(hit?.relativePath == "m/x.dbkv")
}

@Test
func indexReturnsLongestAvailableCheckpoint() {
    let idx = PrefixCacheIndex(fileURL: tmpIndexURL())
    let tokens = (0..<3000).map { $0 }  // checkpoints 256,512,1024,2048

    idx.record(entry(model: "m", tokens: tokens, length: 256, path: "m/a.dbkv"))
    idx.record(entry(model: "m", tokens: tokens, length: 1024, path: "m/b.dbkv"))

    // 2048 isn't recorded; longest present ≤ prompt is 1024.
    let hit = idx.findLongestCheckpoint(modelHash: "m", tokens: tokens)
    #expect(hit?.tokenCount == 1024)
    #expect(hit?.relativePath == "m/b.dbkv")
}

@Test
func indexMissOnDivergentPrefix() {
    let idx = PrefixCacheIndex(fileURL: tmpIndexURL())
    let cached = (0..<600).map { $0 }
    idx.record(entry(model: "m", tokens: cached, length: 512, path: "m/x.dbkv"))

    // A prompt that diverges within the first 256 tokens shares no checkpoint.
    var divergent = cached
    divergent[10] = 99999
    let hit = idx.findLongestCheckpoint(modelHash: "m", tokens: divergent)
    #expect(hit == nil, "divergent prefix must not match")
}

@Test
func indexIsModelScoped_MB1() {
    let idx = PrefixCacheIndex(fileURL: tmpIndexURL())
    let tokens = (0..<600).map { $0 }
    idx.record(entry(model: "A", tokens: tokens, length: 512, path: "A/x.dbkv"))

    #expect(idx.findLongestCheckpoint(modelHash: "A", tokens: tokens)?.tokenCount == 512)
    #expect(idx.findLongestCheckpoint(modelHash: "B", tokens: tokens) == nil,
            "MB-1: model B must not match model A's entry")
}

@Test
func indexTouchBumpsHitMetadata() {
    let idx = PrefixCacheIndex(fileURL: tmpIndexURL())
    let tokens = (0..<300).map { $0 }
    let e = entry(model: "m", tokens: tokens, length: 256, path: "m/x.dbkv", now: 100)
    idx.record(e)

    idx.touch(modelHash: "m", digestHex: e.digestHex, now: 500)
    let after = idx.entry(modelHash: "m", digestHex: e.digestHex)
    #expect(after?.hitCount == 1)
    #expect(after?.lastHitAt == 500)
}

@Test
func indexRemoveAndRemoveModel() {
    let idx = PrefixCacheIndex(fileURL: tmpIndexURL())
    let t = (0..<300).map { $0 }
    let e1 = entry(model: "A", tokens: t, length: 256, path: "A/1.dbkv")
    let e2 = entry(model: "A", tokens: t.map { $0 + 1 }, length: 256, path: "A/2.dbkv")
    let e3 = entry(model: "B", tokens: t, length: 256, path: "B/1.dbkv")
    idx.record(e1); idx.record(e2); idx.record(e3)
    #expect(idx.count == 3)

    let removed = idx.remove(modelHash: "A", digestHex: e1.digestHex)
    #expect(removed?.relativePath == "A/1.dbkv")
    #expect(idx.count == 2)

    let removedModel = idx.removeModel("A")
    #expect(removedModel.count == 1)  // only e2 left under A
    #expect(idx.count == 1)
    #expect(idx.entry(modelHash: "B", digestHex: e3.digestHex) != nil)
}

@Test
func indexLRUOrdering() {
    let idx = PrefixCacheIndex(fileURL: tmpIndexURL())
    let t = (0..<300).map { $0 }
    var e1 = entry(model: "m", tokens: t, length: 256, path: "m/1.dbkv", now: 100)
    let e2 = entry(model: "m", tokens: t.map { $0 + 1 }, length: 256, path: "m/2.dbkv", now: 50)
    e1.lastHitAt = 100
    idx.record(e1); idx.record(e2)

    let lru = idx.entriesLRUFirst(modelHash: "m")
    #expect(lru.first?.relativePath == "m/2.dbkv", "least-recently-hit (lastHitAt 50) should be first")
}

@Test
func indexLRUTieBreakIsDeterministic() {
    // Two entries with the SAME lastHitAt must order deterministically
    // (by digestHex) rather than by undefined dictionary iteration.
    let idx = PrefixCacheIndex(fileURL: tmpIndexURL())
    let t = (0..<300).map { $0 }
    var e1 = entry(model: "m", tokens: t, length: 256, path: "m/1.dbkv")
    var e2 = entry(model: "m", tokens: t.map { $0 + 1 }, length: 256, path: "m/2.dbkv")
    e1.lastHitAt = 777
    e2.lastHitAt = 777  // tie
    idx.record(e1); idx.record(e2)

    let a = idx.entriesLRUFirst(modelHash: "m").map { $0.digestHex }
    let b = idx.entriesLRUFirst(modelHash: "m").map { $0.digestHex }
    #expect(a == b, "tie-break must be stable across calls")
    #expect(a == a.sorted(), "equal-lastHitAt entries must order by digestHex")
}

@Test
func indexPersistsAcrossReload() throws {
    let url = tmpIndexURL()
    let tokens = (0..<600).map { $0 }

    let idx1 = PrefixCacheIndex(fileURL: url)
    let e = entry(model: "m", tokens: tokens, length: 512, path: "m/x.dbkv", bytes: 4242)
    idx1.record(e)
    #expect(idx1.isDirty)
    try idx1.save()
    #expect(!idx1.isDirty, "save clears the dirty flag")

    // Fresh instance loads from disk.
    let idx2 = PrefixCacheIndex(fileURL: url)
    let hit = idx2.findLongestCheckpoint(modelHash: "m", tokens: tokens + [1])
    #expect(hit?.tokenCount == 512)
    #expect(hit?.fileBytes == 4242)

    try? FileManager.default.removeItem(at: url)
}

@Test
func indexCorruptFileStartsEmpty() throws {
    let url = tmpIndexURL()
    try Data("this is not json".utf8).write(to: url)

    let idx = PrefixCacheIndex(fileURL: url)
    #expect(idx.count == 0, "corrupt index file should be treated as empty, not crash")

    try? FileManager.default.removeItem(at: url)
}

@Test
func indexRebuildReplacesContents() {
    let idx = PrefixCacheIndex(fileURL: tmpIndexURL())
    let t = (0..<300).map { $0 }
    idx.record(entry(model: "old", tokens: t, length: 256, path: "old/x.dbkv"))

    let fresh = [
        entry(model: "new", tokens: t, length: 256, path: "new/a.dbkv"),
        entry(model: "new", tokens: t.map { $0 + 1 }, length: 256, path: "new/b.dbkv"),
    ]
    idx.rebuild(from: fresh)
    #expect(idx.count == 2)
    #expect(idx.entries(modelHash: "old").isEmpty)
    #expect(idx.entries(modelHash: "new").count == 2)
}
