// Copyright © 2026 Eigen Labs.
//
// LIVE P5 qualification: SSD complete-checkpoint restore across TWO
// processes on the real LFM2.5-24B-A2B artifact, product-default checkpoint
// precision. Phase "restart-write" (process 1) donates checkpoints for two
// prompts into a test-owned root and records each prompt's cold output hash;
// phase "restart-read" (process 2) reopens the root with the same test key:
// the startup scan finds the entries, the first prompt restores, a corrupted
// entry is dropped and the second prompt is recomputed safely (output equals
// its cold hash), and an incompatible checkpoint identity misses.
//
// The persistent key is a test-owned 32-byte file (DARKBLOOM_LFM25_QUAL_KEY_FILE)
// injected through the factory's code-only key-loader seam; the Secure
// Enclave and Keychain are never used. Root: DARKBLOOM_LFM25_QUAL_SSD_ROOT.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

private enum LFM25Restart {
    static var root: URL? {
        LFM25Qual.environment["DARKBLOOM_LFM25_QUAL_SSD_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func loader() throws -> SSDCacheKeyMaterial.PersistentLoader {
        let path = try #require(LFM25Qual.environment["DARKBLOOM_LFM25_QUAL_KEY_FILE"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        try #require(data.count == 32)
        let key = SymmetricKey(data: data)
        return { _ in key }
    }

    static func prompts(_ model: LFM25Loaded) -> [[Int]] {
        [
            model.encode(LFM25Qual.chatML(LFM25Qual.records(0 ..< 150, salt: 100)
                + " Which warehouse logged record 42? Answer briefly.")),
            model.encode(LFM25Qual.chatML(LFM25Qual.records(0 ..< 140, salt: 400)
                + " Which part number appears most often?")),
        ]
    }

    static let maxTokens = 32
    static var stateFile: URL? { root?.deletingLastPathComponent().appendingPathComponent("restart-state.json") }
}

@Suite("LFM2.5-24B-A2B SSD restart qualification (live, two processes)", .serialized)
struct LFM25RestartQualificationLiveTests {
    @Test("process 1: donate checkpoints and record cold outputs",
          .enabled(if: LFM25Qual.selected("restart-write")))
    func writePhase() async throws {
        let root = try #require(LFM25Restart.root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = try await LFM25Loaded.load()
        let slot = try await LFM25Slot.make(model, maxConcurrent: 4, cacheRoot: root,
                                            keyLoader: try LFM25Restart.loader())
        let store = try #require(slot.store)
        #expect(!store.usesEphemeralKey)
        var colds: [[String: Any]] = []
        for (index, tokens) in LFM25Restart.prompts(model).enumerated() {
            let cold = await LFM25Run.run(slot, tokens: tokens, maxTokens: LFM25Restart.maxTokens,
                                          id: "w-cold-\(index)", cacheEnabled: false)
            let before = store.stats().filesWritten
            let donor = await LFM25Run.run(slot, tokens: tokens, maxTokens: LFM25Restart.maxTokens,
                                           id: "w-donor-\(index)")
            let written = try await slot.waitForWrites(above: before)
            #expect(written > before)
            #expect(donor.text == cold.text)
            colds.append(["cold": cold.evidence, "donor": donor.evidence, "filesWritten": written])
        }
        let state: [String: Any] = ["phase": "write", "pid": ProcessInfo.processInfo.processIdentifier,
                                    "prompts": colds, "store": store.stats().evidence]
        let stateFile = try #require(LFM25Restart.stateFile)
        try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]).write(to: stateFile)
        LFM25Qual.writeEvidence("restart-write", state)
        await slot.bridge.shutdown()
    }

    @Test("process 2: scan, restore, corrupted entry -> safe recompute, incompatible identity -> miss",
          .enabled(if: LFM25Qual.selected("restart-read")))
    func readPhase() async throws {
        let root = try #require(LFM25Restart.root)
        let stateFile = try #require(LFM25Restart.stateFile)
        let state = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: stateFile)) as? [String: Any])
        let written = try #require(state["prompts"] as? [[String: Any]])
        let coldSHA = try written.map { try #require(($0["cold"] as? [String: Any])?["textSHA"] as? String) }
        #expect((state["pid"] as? Int32).map { $0 != ProcessInfo.processInfo.processIdentifier } ?? true)
        let model = try await LFM25Loaded.load()
        let prompts = LFM25Restart.prompts(model)
        var slot = try await LFM25Slot.make(model, maxConcurrent: 4, cacheRoot: root,
                                            keyLoader: try LFM25Restart.loader())
        let store = try #require(slot.store)
        let scanned = store.stats()
        #expect(scanned.entries >= 2, "the startup scan must index the previous process's files")

        // Determinism across processes: the uncached run reproduces process 1.
        let cold0 = await LFM25Run.run(slot, tokens: prompts[0], maxTokens: LFM25Restart.maxTokens,
                                       id: "r-cold-0", cacheEnabled: false)
        #expect(LFM25Qual.sha(cold0.text) == coldSHA[0])
        let warm0 = await LFM25Run.run(slot, tokens: prompts[0], maxTokens: LFM25Restart.maxTokens, id: "r-warm-0")
        #expect(warm0.error == nil)
        #expect((warm0.prefillTokensSaved ?? 0) > 0, "restart restore must reuse the persisted checkpoint")
        let afterRestore = store.stats()

        // Corrupt every persisted checkpoint payload (header left intact so
        // the scan's metadata check still indexes it), then the second prompt
        // must fall back to an exact cold recompute.
        let corrupted = try corruptPayloads(under: root)
        #expect(corrupted > 0)
        let warm1 = await LFM25Run.run(slot, tokens: prompts[1], maxTokens: LFM25Restart.maxTokens, id: "r-corrupt-1")
        let afterCorrupt = store.stats()
        #expect(warm1.error == nil)
        #expect((warm1.prefillTokensSaved ?? 0) == 0)
        #expect(LFM25Qual.sha(warm1.text) == coldSHA[1], "a dropped entry must recompute the cold output")
        #expect(afterCorrupt.corruptDropped > afterRestore.corruptDropped || afterCorrupt.misses > afterRestore.misses)
        await slot.bridge.shutdown()
        MLX.Memory.clearCache()

        // Incompatible identity (another build/revision tag) over the same
        // root and key: nothing is visible, the request misses.
        slot = try await LFM25Slot.make(model, maxConcurrent: 4, cacheRoot: root,
                                        identityTag: "lfm25-qual-other-revision",
                                        keyLoader: try LFM25Restart.loader())
        let otherEntries = slot.store?.stats().entries ?? -1
        let other = await LFM25Run.run(slot, tokens: prompts[0], maxTokens: LFM25Restart.maxTokens, id: "r-other")
        #expect(otherEntries == 0)
        #expect((other.prefillTokensSaved ?? 0) == 0)
        await slot.bridge.shutdown()

        let result: [String: Any] = [
            "phase": "read", "scanned": scanned.evidence, "cold0": cold0.evidence,
            "cold0MatchesProcess1": LFM25Qual.sha(cold0.text) == coldSHA[0],
            "warm0": warm0.evidence, "warm0EqualsCold": LFM25Qual.sha(warm0.text) == coldSHA[0],
            "warm0CommonPrefixChars": LFM25Qual.commonPrefix(warm0.text, cold0.text),
            "afterRestore": afterRestore.evidence, "corruptedFiles": corrupted,
            "corruptRecompute": warm1.evidence, "corruptRecomputeEqualsCold": LFM25Qual.sha(warm1.text) == coldSHA[1],
            "afterCorrupt": afterCorrupt.evidence, "otherIdentityEntries": otherEntries,
            "otherIdentity": other.evidence,
        ]
        LFM25Qual.writeEvidence("restart-read", result)
        print("LFM25-QUAL restart scanned=\(scanned.entries) warmSaved=\(warm0.prefillTokensSaved ?? -1) "
            + "warmEqualsCold=\(LFM25Qual.sha(warm0.text) == coldSHA[0]) corrupted=\(corrupted) "
            + "corruptSaved=\(warm1.prefillTokensSaved ?? -1) corruptDropped=\(afterCorrupt.corruptDropped) "
            + "otherEntries=\(otherEntries) otherSaved=\(other.prefillTokensSaved ?? -1)")
    }

    /// Flips 64 bytes in the middle of every checkpoint file under `root`.
    private func corruptPayloads(under root: URL) throws -> Int {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        var count = 0
        while let file = enumerator?.nextObject() as? URL {
            guard file.pathExtension == SSDBlockStore.fileExtension else { continue }
            let handle = try FileHandle(forUpdating: file)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            guard size > 4_096 else { continue }
            let offset = size / 2
            try handle.seek(toOffset: offset)
            let original = try handle.read(upToCount: 64) ?? Data()
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: Data(original.map { $0 ^ 0xA5 }))
            count += 1
        }
        return count
    }
}
