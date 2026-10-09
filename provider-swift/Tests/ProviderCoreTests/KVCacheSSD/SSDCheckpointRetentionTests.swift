import Foundation
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Measured SSD checkpoint retention", .serialized)
struct SSDCheckpointRetentionTests {
    @Test("Opt-in excludes MiMo and malformed values")
    func policyGate() {
        for model in ["gemma-4-26b-a4b-it", "gpt-oss-20b", "qwen3.8-27b"] {
            #expect(!SSDPrefixCachePolicy.utilityRetentionEnabled(environment: [:], modelId: model))
            #expect(SSDPrefixCachePolicy.utilityRetentionEnabled(
                environment: [SSDPrefixCachePolicy.utilityRetentionFlag: "true"], modelId: model))
        }
        #expect(!SSDPrefixCachePolicy.utilityRetentionEnabled(
            environment: [SSDPrefixCachePolicy.utilityRetentionFlag: "true"], modelId: "MiMo-v2.6"))
        #expect(!SSDPrefixCachePolicy.utilityRetentionEnabled(
            environment: [SSDPrefixCachePolicy.utilityRetentionFlag: "garbage"], modelId: "gpt-oss-20b"))
    }

    @Test("Real encrypted eviction preserves useful old prefixes and beats LRU on recurring small prompts")
    func usefulCheckpointSurvives() async throws {
        var reusedTokens: [Int] = []
        for utility in [false, true] {
            let f = try SSDHybridCheckpointTestFixture(tokenCount: 1025)
            defer { f.remove() }
            let budget = SSDDiskBudget()
            let store = try f.makeStore(diskBudget: budget, utilityRetentionEnabled: utility)
            #expect(try await f.donate(store, position: 256) == [256])
            #expect(try await f.donate(store, receipt: 11, position: 512) == [512])
            let oldURL = f.file(store, position: 256)
            let newURL = f.file(store, position: 512)
            let oldTag = try #require(SSDPrefixCache.hexDecode(oldURL.deletingPathExtension().lastPathComponent))
            let newTag = try #require(SSDPrefixCache.hexDecode(newURL.deletingPathExtension().lastPathComponent))
            var request = f.request()
            request.promptTokens = Array(f.tokens.prefix(257))
            let shortRequest = request
            let stage = await store.stage(requestID: .init(20), request: shortRequest,
                reserveReadScratch: f.reserveReadScratch) { try f.codec.plan(manifest: $0, request: shortRequest) }
            #expect(stage.staged)
            let receipt = store.makeRetentionReceipt(requestID: .init(20), stageMillis: 20,
                prefillTokensPerSecond: 512)
            let taken = try #require(store.takeStaged(requestID: .init(20), tokens: request.promptTokens,
                cacheSalt: "tenant-a", maximumSequenceLength: 265))
            receipt?.complete(hitUsage(prompt: 257, saved: 256))
            receipt?.complete(hitUsage(prompt: 257, saved: 256))
            taken.close()
            store.completeStaging(requestID: .init(20))
            #expect(store.stats().retentionAdoptions == (utility ? 1 : 0))
            let now = Int64(Date().timeIntervalSince1970)
            store.index.touch(tags16: [oldTag], now: now - 10)
            store.index.touch(tags16: [newTag], now: now)
            let limit = try #require(store.index.fileBytes(tags16: [newTag][...])?.first)
            #expect(budget.enforce(budgetBytes: limit, now: now + 31) == 1)
            #expect(budget.totalBytes <= limit)
            #expect(FileManager.default.fileExists(atPath: oldURL.path) == utility)
            #expect(FileManager.default.fileExists(atPath: newURL.path) != utility)
            let reuse = await store.stage(requestID: .init(21), request: shortRequest,
                reserveReadScratch: f.reserveReadScratch) { try f.codec.plan(manifest: $0, request: shortRequest) }
            if case .staged(_, let saved, _) = reuse.disposition { reusedTokens.append(saved) }
            else { reusedTokens.append(0) }
            print("SSD retention fixture mode=\(utility ? "utility" : "LRU") "
                + "cap_bytes=\(limit) retained_bytes=\(budget.totalBytes) "
                + "next_saved_tokens=\(reusedTokens.last ?? 0) "
                + "credited_adoptions=\(store.stats().retentionAdoptions) "
                + "counterfactual_prefill_tps=512 counterfactual_stage_ms=20")
            await store.closeAndWait()
            #expect(await f.budget.outstandingReservedBytes() == 0)
        }
        #expect(reusedTokens == [0, 256])
    }

    @Test("Staging, failed adoption, abandon, and reused IDs do not invent successful reuse")
    func receiptLifecycle() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let store = try f.makeStore(utilityRetentionEnabled: true)
        #expect(try await f.donate(store) == [256])
        let tag = try #require(store.index.allTags().first)
        #expect(store.makeRetentionReceipt(requestID: .init(20), stageMillis: 0,
            prefillTokensPerSecond: 512) == nil)
        for disposition in [CBv2PrefixCacheOutcome.adoptionFailed, .skippedCapacity, .hit] {
            let result = await store.stage(requestID: .init(20), request: f.request(),
                reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
            #expect(result.staged)
            let receipt = try #require(store.makeRetentionReceipt(requestID: .init(20),
                stageMillis: 20, prefillTokensPerSecond: 512))
            if disposition == .hit { await store.abandonStaging(requestID: .init(20)) }
            var usage = hitUsage(prompt: 513, saved: 256)
            usage.prefixCacheOutcome = disposition
            receipt.complete(usage)
            await store.abandonStaging(requestID: .init(20))
        }
        #expect(store.stats().retentionAdoptions == 0)
        #expect(store.index.retentionPriority(tag16: tag, now: Int64(Date().timeIntervalSince1970))?.savedMillisPerByte == 0)
        let first = await store.stage(requestID: .init(30), request: f.request(),
            reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(first.staged)
        let stale = try #require(store.makeRetentionReceipt(requestID: .init(30), stageMillis: 20,
            prefillTokensPerSecond: 512))
        await store.abandonStaging(requestID: .init(30))
        let replacement = await store.stage(requestID: .init(30), request: f.request(),
            reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(replacement.staged)
        stale.complete(hitUsage(prompt: 513, saved: 256))
        #expect(store.stats().retentionAdoptions == 0)
        let current = try #require(store.makeRetentionReceipt(requestID: .init(30), stageMillis: 20,
            prefillTokensPerSecond: 512))
        store.close()
        current.complete(hitUsage(prompt: 513, saved: 256))
        #expect(store.stats().retentionAdoptions == 0)
        await store.closeAndWait()
    }

    @Test("Whole-root sweeping honors live utility and falls back after unload")
    func wholeRootUsesSameOrder() async throws {
        for unloaded in [false, true] {
            let f = try SSDHybridCheckpointTestFixture(tokenCount: 1025)
            defer { f.remove() }
            let store = try f.makeStore(diskBudget: .shared, utilityRetentionEnabled: true)
            #expect(try await f.donate(store, position: 256) == [256])
            #expect(try await f.donate(store, receipt: 11, position: 512) == [512])
            let old = f.file(store, position: 256)
            let new = f.file(store, position: 512)
            let tag = try #require(SSDPrefixCache.hexDecode(old.deletingPathExtension().lastPathComponent))
            let generation = try #require(store.index.retentionGeneration(tag16: tag))
            let now = Int64(Date().timeIntervalSince1970)
            store.index.creditRetention(tag16: tag, generation: generation, savedMillis: 1000, now: now)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(now - 10))],
                ofItemAtPath: old.path)
            let limit = try #require((try new.resourceValues(forKeys: [.fileSizeKey])).fileSize)
            if unloaded { await store.closeAndWait() }
            let result = SSDWholeRootMaintainer().maintain(root: f.root, ttlSeconds: 0,
                nowSeconds: now + 31, budgetBytes: limit)
            #expect(result.budgetEvicted == 1)
            #expect(result.bytesAfter <= limit)
            #expect(FileManager.default.fileExists(atPath: old.path) != unloaded)
            await store.closeAndWait()
        }
    }

    @Test("Eviction and rewrite between staging and submission cannot credit the replacement")
    func stagedGenerationSurvivesSubmissionWaits() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let store = try f.makeStore(utilityRetentionEnabled: true)
        #expect(try await f.donate(store) == [256])
        let stage = await store.stage(requestID: .init(30), request: f.request(),
            reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(stage.staged)
        let tag = try #require(store.index.allTags().first)
        let originalGeneration = try #require(store.index.retentionGeneration(tag16: tag))
        #expect(store.evictOldestEntry() > 0)
        #expect(try await f.donate(store, receipt: 31) == [256])
        #expect(store.index.retentionGeneration(tag16: tag) != originalGeneration)
        let receipt = store.makeRetentionReceipt(requestID: .init(30), stageMillis: 20,
            prefillTokensPerSecond: 512)
        #expect(receipt == nil)
        let adopted = try #require(store.takeStaged(requestID: .init(30), tokens: f.tokens,
            cacheSalt: "tenant-a", maximumSequenceLength: 521))
        receipt?.complete(hitUsage(prompt: 513, saved: 256))
        adopted.close()
        #expect(store.stats().retentionAdoptions == 0)
        #expect(store.index.retentionPriority(tag16: tag,
            now: Int64(Date().timeIntervalSince1970))?.savedMillisPerByte == 0)
        await store.closeAndWait()
        #expect(await f.budget.outstandingReservedBytes() == 0)
    }

    @Test("Replacement and backwards clocks discard stale utility; decay favors recent useful demand")
    func boundedEvidence() throws {
        let index = SSDBlockIndex()
        let tag = Data([1])
        index.insert(tag16: tag, fileBytes: 100, lastAccess: 0)
        let old = try #require(index.retentionGeneration(tag16: tag))
        index.creditRetention(tag16: tag, generation: old, savedMillis: 100, now: 100)
        #expect(index.retentionPriority(tag16: tag, now: 100)?.savedMillisPerByte == 1)
        #expect(index.retentionPriority(tag16: tag, now: 400)?.savedMillisPerByte == 0.5)
        #expect(index.retentionPriority(tag16: tag, now: 99)?.savedMillisPerByte == 0)
        index.insert(tag16: tag, fileBytes: 100, lastAccess: 100)
        index.creditRetention(tag16: tag, generation: old, savedMillis: 100, now: 100)
        #expect(index.retentionPriority(tag16: tag, now: 100)?.savedMillisPerByte == 0)
    }

    @Test("New uncredited demand has a bounded chance to be adopted without extending TTL")
    func newEntryProbation() throws {
        let index = SSDBlockIndex()
        let popular = Data([1])
        let newcomer = Data([2])
        index.insert(tag16: popular, fileBytes: 100, lastAccess: 0)
        index.creditRetention(tag16: popular,
            generation: try #require(index.retentionGeneration(tag16: popular)), savedMillis: 100, now: 100)
        index.insert(tag16: newcomer, fileBytes: 100, lastAccess: 100)
        #expect(index.retentionEntries(now: 129).first?.tag16 == popular)
        index.touch(tags16: [newcomer], now: 129)
        #expect(index.retentionEntries(now: 130).first?.tag16 == newcomer)
        #expect(index.expired(now: 140, ttlSeconds: 10).contains(newcomer))
    }

    private func hitUsage(prompt: Int, saved: Int) -> CBv2Usage {
        .init(promptTokens: prompt, completionTokens: 0, prefixCacheOutcome: .hit,
            prefixCacheTier: .snapshot, prefixCacheMatchedTokens: saved,
            prefixCachePrefillTokensSaved: saved)
    }
}
