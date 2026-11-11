// Copyright © 2026 Eigen Labs.
//
// LIVE P3/P4/P6 qualification on the real LFM2.5-24B-A2B artifact through the
// production bundle and the SSD complete-checkpoint tier (isolated test root):
//   P3 exact repeat, multi-turn suffix continuation, divergent branches
//      (coordinator repeated-prefix hint -> fork checkpoint -> third branch
//      restores at that boundary);
//   P4 concurrent reuse of one checkpoint with a member cancelled mid-decode,
//      then no leaked request, KV, reservation or staging bytes;
//   P6 tenant-salt isolation (cache scope) and incompatible checkpoint
//      identity (another build/revision tag) -> miss, then the original
//      identity reopened from disk -> hit.
// Run under the product default checkpoint precision ("balanced", owner
// decision D1: warm-vs-cold token equality is REPORTED, not asserted) and,
// as a labelled diagnostic, under "native" storage where restores are exact.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

@Suite("LFM2.5-24B-A2B prefix reuse qualification (live)", .serialized,
       .enabled(if: LFM25Qual.selected("prefix")))
struct LFM25PrefixQualificationLiveTests {
    private static let maxTokens = 32

    @Test("partial prefix, suffix continuation, divergent branches, concurrency, tenant salt, identity")
    func prefixReuse() async throws {
        let model = try await LFM25Loaded.load()
        var results: [String: Any] = ["loadSeconds": model.loadSeconds]
        for precision in ["balanced", "native"] {
            results[precision] = try await qualify(model, precision: precision)
        }
        LFM25Qual.writeEvidence("prefix", results)
    }

    private func qualify(_ model: LFM25Loaded, precision: String) async throws -> [String: Any] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lfm25-qual-prefix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // One in-memory test key shared by every slot of this run, so a
        // reopened store can read what an earlier store wrote.
        let key = SymmetricKey(size: .bits256)
        let loader: SSDCacheKeyMaterial.PersistentLoader = { _ in key }
        let exact = precision == "native"
        var slot = try await LFM25Slot.make(model, maxConcurrent: 4, cacheRoot: root,
                                            checkpointPrecision: precision, keyLoader: loader)
        let store = try #require(slot.store)
        #expect(!store.usesEphemeralKey)
        var out: [String: Any] = ["storeLayout": store.config.backendLayout,
                                  "minEffectiveTokens": store.config.minEffectiveTokens]
        let idle = try await slot.settled()

        func turn(_ content: String) -> String { LFM25Qual.chatML(content) }
        let base = LFM25Qual.records(0 ..< 150, salt: 100)
        let p = model.encode(turn(base + " Which warehouse logged record 42? Answer briefly."))

        // P3a: donor (cold, writes) then exact repeat (warm).
        let coldP = await LFM25Run.run(slot, tokens: p, maxTokens: Self.maxTokens, id: "p-cold", cacheEnabled: false)
        let donor = await LFM25Run.run(slot, tokens: p, maxTokens: Self.maxTokens, id: "p-donor")
        let written = try await slot.waitForWrites(above: 0)
        #expect(written > 0)
        let warm = await LFM25Run.run(slot, tokens: p, maxTokens: Self.maxTokens, id: "p-warm")
        #expect((warm.prefillTokensSaved ?? 0) > 0)
        #expect(donor.text == coldP.text, "the donor ran cold and must equal the uncached run")
        if exact { #expect(warm.text == coldP.text) }
        out["exactRepeat"] = compare(cold: coldP, warm: warm, donor: donor, written: written, store: store)

        // P3b: multi-turn suffix continuation sharing the whole first turn.
        let continuation = model.encode(
            "<|startoftext|><|im_start|>user\n\(base) Which warehouse logged record 42? Answer briefly."
                + "<|im_end|>\n<|im_start|>assistant\nWarehouse 3.<|im_end|>\n"
                + "<|im_start|>user\nAnd record 43?<|im_end|>\n<|im_start|>assistant\n<think>")
        let coldS = await LFM25Run.run(slot, tokens: continuation, maxTokens: Self.maxTokens,
                                       id: "s-cold", cacheEnabled: false)
        let warmS = await LFM25Run.run(slot, tokens: continuation, maxTokens: Self.maxTokens, id: "s-warm")
        #expect((warmS.prefillTokensSaved ?? 0) > 0, "suffix continuation must restore the first turn")
        if exact { #expect(warmS.text == coldS.text) }
        var suffix = compare(cold: coldS, warm: warmS, store: store)
        suffix["sharedTokensWithP"] = commonTokens(p, continuation)
        out["suffixContinuation"] = suffix

        // P3c: divergent branches. Branch B shares ~2,050 tokens with P and
        // carries the coordinator's repeated-prefix hint, so the engine keeps
        // and donates the stride checkpoint at or below the shared prefix;
        // branch C diverges from both after the same prefix and must restore
        // at that boundary.
        let shared = LFM25Qual.records(0 ..< 120, salt: 100)
        let branchB = model.encode(turn(shared + " " + LFM25Qual.records(500 ..< 530) + " Which part repeats?"))
        let branchC = model.encode(turn(shared + " " + LFM25Qual.records(700 ..< 720) + " Which crate count is largest?"))
        let sharedB = commonTokens(p, branchB)
        let beforeB = store.stats().filesWritten
        let runB = await LFM25Run.run(slot, tokens: branchB, maxTokens: Self.maxTokens, id: "b-branch",
                                      donationDemand: SSDCheckpointDonationDemand(repeatedPrefixTokens: sharedB))
        let writtenB = try await slot.waitForWrites(above: beforeB)
        let coldC = await LFM25Run.run(slot, tokens: branchC, maxTokens: Self.maxTokens, id: "c-cold", cacheEnabled: false)
        let warmC = await LFM25Run.run(slot, tokens: branchC, maxTokens: Self.maxTokens, id: "c-warm")
        let sharedC = commonTokens(branchB, branchC)
        #expect(runB.error == nil && warmC.error == nil)
        #expect((warmC.prefillTokensSaved ?? 0) > 0, "branch C must restore the fork checkpoint")
        #expect((warmC.prefillTokensSaved ?? 0) <= sharedC)
        if exact { #expect(warmC.text == coldC.text) }
        var branches = compare(cold: coldC, warm: warmC, store: store)
        branches["branchB"] = runB.evidence
        branches["sharedTokensPB"] = sharedB
        branches["sharedTokensBC"] = sharedC
        branches["filesWrittenAfterB"] = writtenB
        out["divergentBranches"] = branches

        // P4: four concurrent continuations reuse P's checkpoint; one is
        // cancelled mid-decode. Cold references first.
        let followUps = ["And record 44?", "And record 45?", "And record 46?", "And record 47?"]
        let concurrentPrompts = followUps.map { follow in
            model.encode("<|startoftext|><|im_start|>user\n\(base) Which warehouse logged record 42? "
                + "Answer briefly.<|im_end|>\n<|im_start|>assistant\nWarehouse 3.<|im_end|>\n"
                + "<|im_start|>user\n\(follow)<|im_end|>\n<|im_start|>assistant\n<think>")
        }
        var colds: [LFM25Run] = []
        for (index, tokens) in concurrentPrompts.enumerated() {
            colds.append(await LFM25Run.run(slot, tokens: tokens, maxTokens: Self.maxTokens,
                                            id: "k-cold-\(index)", cacheEnabled: false,
                                            topLogprobs: 5, repetitionPenalty: 1.0))
        }
        let consumptionsBefore = store.stats().stageConsumptions
        let warmSlot = slot
        let concurrent = await withTaskGroup(of: (Int, LFM25Run).self) { group in
            for (index, tokens) in concurrentPrompts.enumerated() {
                group.addTask {
                    (index, await LFM25Run.run(warmSlot, tokens: tokens, maxTokens: Self.maxTokens,
                                               id: "k-warm-\(index)", cancelAfterChunks: index == 1 ? 4 : nil,
                                               topLogprobs: 5, repetitionPenalty: 1.0))
                }
            }
            var runs: [Int: LFM25Run] = [:]
            for await (index, run) in group { runs[index] = run }
            return runs
        }
        let settled = try await slot.settled(idle: idle)
        try await waitForStagingDrain(store)
        let stats = store.stats()
        var rows: [[String: Any]] = []
        for index in concurrentPrompts.indices {
            let run = try #require(concurrent[index])
            var item = run.evidence
            item["equalsCold"] = run.text == colds[index].text
            item["commonPrefixChars"] = LFM25Qual.commonPrefix(run.text, colds[index].text)
            // The warm rows run batched against SEQUENTIAL cold references,
            // so batch-shape near-tie flips are possible (see the batching
            // suite); under exact storage a row must match or differ first at
            // a near-tie swap. Balanced (lossy) restores are reported only.
            let divergence = LFM25Divergence(reference: colds[index].logprobs, run: run.logprobs)
            let nearTie = divergence.isIdentical
                || (divergence.isTopTwoSwap(within: 1.0) && divergence.prefixMaxAbsDelta <= 1.0)
            item["divergence"] = divergence.evidence
            item["identicalOrNearTie"] = nearTie
            #expect((run.prefillTokensSaved ?? 0) > 0)
            if index == 1 {
                #expect(run.completionTokens < colds[index].completionTokens)
            } else {
                #expect(run.error == nil)
            }
            if exact { #expect(nearTie, "row \(index): \(divergence.evidence)") }
            rows.append(item)
        }
        #expect(stats.stageConsumptions > consumptionsBefore)
        #expect(settled.activeRequests == 0 && settled.waitingRequests == 0)
        #expect(settled.kvBytesInUse == idle.kvBytesInUse)
        #expect(settled.kvBytesReserved == idle.kvBytesReserved)
        #expect(stats.stagedBytesInUse == 0)
        out["concurrentReuse"] = ["rows": rows, "idle": idle.evidence, "settled": settled.evidence,
                                  "store": stats.evidence]

        // P6a: tenant salt (cache scope).
        // Long enough (~2,500 tokens) that a checkpoint boundary clears the
        // store's effective-token floor.
        let tenantPrompt = model.encode(turn(LFM25Qual.records(0 ..< 140, salt: 300) + " Which part is most common?"))
        let beforeTenant = store.stats().filesWritten
        let tenantA = await LFM25Run.run(slot, tokens: tenantPrompt, maxTokens: Self.maxTokens, id: "t-a1",
                                         scope: "tenant-a")
        let tenantWritten = try await slot.waitForWrites(above: beforeTenant)
        #expect(tenantWritten > beforeTenant, "tenant-a must donate a checkpoint")
        let tenantB = await LFM25Run.run(slot, tokens: tenantPrompt, maxTokens: Self.maxTokens, id: "t-b",
                                         scope: "tenant-b")
        let unscoped = await LFM25Run.run(slot, tokens: tenantPrompt, maxTokens: Self.maxTokens, id: "t-none")
        let tenantA2 = await LFM25Run.run(slot, tokens: tenantPrompt, maxTokens: Self.maxTokens, id: "t-a2",
                                          scope: "tenant-a")
        #expect((tenantB.prefillTokensSaved ?? 0) == 0, "another tenant must never reuse tenant-a's checkpoint")
        #expect((unscoped.prefillTokensSaved ?? 0) == 0)
        #expect((tenantA2.prefillTokensSaved ?? 0) > 0)
        out["tenantSalt"] = ["filesWrittenByA1": tenantWritten - beforeTenant, "a1": tenantA.evidence, "b": tenantB.evidence, "unscoped": unscoped.evidence,
                             "a2": tenantA2.evidence]
        await slot.bridge.shutdown()
        MLX.Memory.clearCache()

        // P6b: an incompatible checkpoint identity (another build/revision
        // tag) over the SAME root and key sees nothing; the original identity
        // reopened from disk (a new store instance) restores again.
        slot = try await LFM25Slot.make(model, maxConcurrent: 4, cacheRoot: root, checkpointPrecision: precision,
                                        identityTag: "lfm25-qual-other-revision", keyLoader: loader)
        let otherEntries = slot.store?.stats().entries ?? -1
        let other = await LFM25Run.run(slot, tokens: p, maxTokens: Self.maxTokens, id: "id-other")
        #expect(otherEntries == 0)
        #expect((other.prefillTokensSaved ?? 0) == 0)
        await slot.bridge.shutdown()
        MLX.Memory.clearCache()
        slot = try await LFM25Slot.make(model, maxConcurrent: 4, cacheRoot: root, checkpointPrecision: precision,
                                        keyLoader: loader)
        let reopenedEntries = slot.store?.stats().entries ?? -1
        let reopened = await LFM25Run.run(slot, tokens: p, maxTokens: Self.maxTokens, id: "id-reopened")
        #expect(reopenedEntries > 0)
        #expect((reopened.prefillTokensSaved ?? 0) > 0)
        if exact { #expect(reopened.text == coldP.text) }
        out["identity"] = ["otherRevisionEntries": otherEntries, "otherRevision": other.evidence,
                           "reopenedEntries": reopenedEntries, "reopened": reopened.evidence,
                           "reopenedEqualsCold": reopened.text == coldP.text]
        await slot.bridge.shutdown()
        MLX.Memory.clearCache()
        print("LFM25-QUAL prefix [\(precision)] exactRepeatSaved=\(warm.prefillTokensSaved ?? -1) "
            + "warmEqualsCold=\(warm.text == coldP.text) suffixSaved=\(warmS.prefillTokensSaved ?? -1) "
            + "suffixEqualsCold=\(warmS.text == coldS.text) branchCSaved=\(warmC.prefillTokensSaved ?? -1) "
            + "branchEqualsCold=\(warmC.text == coldC.text) tenantB=\(tenantB.prefillTokensSaved ?? -1) "
            + "otherIdentity=\(other.prefillTokensSaved ?? -1) reopened=\(reopened.prefillTokensSaved ?? -1)")
        return out
    }

    private func commonTokens(_ a: [Int], _ b: [Int]) -> Int { zip(a, b).prefix { $0 == $1 }.count }

    private func compare(
        cold: LFM25Run, warm: LFM25Run, donor: LFM25Run? = nil, written: Int? = nil,
        store: SSDHybridCheckpointStore
    ) -> [String: Any] {
        var out: [String: Any] = [
            "cold": cold.evidence, "warm": warm.evidence, "warmEqualsCold": warm.text == cold.text,
            "commonPrefixChars": LFM25Qual.commonPrefix(warm.text, cold.text), "store": store.stats().evidence,
        ]
        if let donor { out["donor"] = donor.evidence }
        if let written { out["filesWritten"] = written }
        return out
    }

    private func waitForStagingDrain(_ store: SSDHybridCheckpointStore) async throws {
        for _ in 0 ..< 100 where store.stats().stagedBytesInUse > 0 || store.stats().writeHostBytesInUse > 0 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
