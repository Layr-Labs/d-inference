// Copyright © 2026 Eigen Labs.
// Explicit full-artifact mechanics qualification. Ephemeral fixture crypto is
// not Keychain, signed persistence, hosted routing, or a production cache root.
import CryptoKit
import Foundation
import MLX
import MLXLLM
@testable import MLXLMCommon
import MLXVLM
import Testing
@testable import ProviderCore

@Suite("Bonsai full-artifact encrypted checkpoint lifecycle", .serialized)
struct BonsaiEncryptedCheckpointLiveTests {
    private struct Output: Sendable {
        var tokens: [Int] = []
        var finish: CBv2FinishReason?
        var usage: CBv2Usage?
    }

    private static func collect(_ stream: AsyncStream<CBv2Event>) async -> Output {
        var result = Output()
        for await event in stream {
            switch event {
            case .delta(_, let tokens, _): result.tokens += tokens
            case .finished(let reason, let usage):
                result.finish = reason
                result.usage = usage
            }
        }
        return result
    }

    private final class Fixture {
        let root: URL
        let modelRoot: URL
        let key = SymmetricKey(size: .bits256)
        let identity = CBv2CompleteCheckpointIdentity(
            modelAggregateHash: "test-only-qualified-bonsai2-artifact",
            promptContractID: "synthetic-native-token-ids",
            buildID: "private-bonsai-exact-candidate",
            numericsFingerprint: "native-fp32")

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("bonsai-checkpoint-live-\(UUID().uuidString)", isDirectory: true)
            modelRoot = root.appendingPathComponent("0123456789ab", isDirectory: true)
            try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
        }

        func store() -> SSDHybridCheckpointStore {
            let store = SSDHybridCheckpointStore(config: .init(
                modelId: "ternary-bonsai-2-27b", identity: identity,
                backendLayout: CBv2CompleteCheckpointManifest.pagedLayout,
                root: modelRoot, dedicatedRoot: root, epochStore: nil,
                maxReadBytes: 512 << 20, maxStageMillis: 60_000,
                minEffectiveTokens: 256, ttlSeconds: 3600, strictFsync: false,
                nowSeconds: { Int64(Date().timeIntervalSince1970) },
                diskBudgetBytes: { 2 << 30 }, maintainWholeRoot: {}),
                kekKey: key, kvBudget: nil, diskBudget: SSDDiskBudget(), maxWriteBytesPerDay: 0)
            store.scanOnDisk()
            return store
        }

        func checkpointFiles() throws -> [URL] {
            let enumerator = try #require(FileManager.default.enumerator(at: modelRoot,
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]))
            return try enumerator.compactMap { item -> URL? in
                guard let file = item as? URL, file.pathExtension == "dbk3",
                    try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
                else { return nil }
                return file
            }
        }

        func removeGeneratedFiles() { try? FileManager.default.removeItem(at: root) }
    }

    private func stage(_ store: SSDHybridCheckpointStore, engine: EngineV2,
                       request: CBv2Request) async -> SSDPrefixCacheStageResult {
        await store.stage(requestID: request.prefixCacheReceiptID!, request: request,
            reserveReadScratch: { try engine.reserveCompleteCheckpointReadScratch() },
            makeImportPlan: { try engine.planCompleteCheckpointImport(manifest: $0, request: request) })
    }

    private func runRound(model: any LanguageModel, tokenizer: any MLXLMCommon.Tokenizer,
                          store: SSDHybridCheckpointStore, checkpointTokens: Int,
                          expected: [Int]?, reopened: Bool) async throws -> [Int] {
        let built = try EngineV2Factory.makeProductionBuild(model: model,
            modelID: "ternary-bonsai-2-27b", tokenizer: tokenizer,
            kvBytesCapacity: 4 << 30, maxConcurrentRequests: 2,
            completePrefixCache: store, kvBackend: .paged, maxContextLength: 8192)
        #expect(built.kvBackendKind == .paged)
        #expect(built.kvBackendFallbackReason == nil)
        let engine = try #require(built.engine as? EngineV2)
        let tokens = (0..<(checkpointTokens + 7)).map { 37 + $0 % 500 }
        let request = CBv2Request(id: .init(11), promptTokens: tokens,
            sampling: .init(temperature: 0), maxTokens: 16, cacheSalt: "synthetic-tenant-a",
            prefixCacheReceiptID: .init(101))
        do {
            if reopened {
                let restored = await stage(store, engine: engine, request: request)
                try #require(restored.staged)
            } else {
                let cold = await stage(store, engine: engine, request: request)
                #expect(cold.disposition == .missAbsent)
            }
            let first = await Self.collect(try engine.submit(request))
            try await BonsaiNativeFixtureDrain.require(engine)
            #expect(first.finish == .length && first.tokens.count == 16)
            if let expected { #expect(first.tokens == expected) }
            if reopened { #expect(first.usage?.prefixCachePrefillTokensSaved == checkpointTokens) }
            await store.waitForWritesForTesting()
            try #require(store.stats().entries > 0)
            #expect(store.stats().stagedBytesInUse == 0)

            var warm = request
            warm.id = .init(12)
            warm.prefixCacheReceiptID = .init(102)
            let hit = await stage(store, engine: engine, request: warm)
            try #require(hit.staged)
            let result = await Self.collect(try engine.submit(warm))
            try await BonsaiNativeFixtureDrain.require(engine)
            #expect(result.finish == .length && result.tokens == first.tokens)
            #expect(result.usage?.prefixCachePrefillTokensSaved == checkpointTokens)
            #expect(result.usage?.prefixCacheTier == .snapshot)
            await store.waitForWritesForTesting()
            #expect(store.stats().stagedBytesInUse == 0)

            var isolated = request
            isolated.id = .init(13)
            isolated.prefixCacheReceiptID = .init(103)
            isolated.cacheSalt = "synthetic-tenant-b"
            let tenantMiss = await stage(store, engine: engine, request: isolated)
            #expect(tenantMiss.disposition == .missAbsent)
            var changed = request
            changed.id = .init(14)
            changed.prefixCacheReceiptID = .init(104)
            changed.promptTokens[0] += 1
            let changedMiss = await stage(store, engine: engine, request: changed)
            #expect(changedMiss.disposition == .missAbsent)
            try await BonsaiNativeFixtureDrain.require(engine)
            await engine.shutdown()
            await store.closeAndWait()
            #expect(store.stats().stagedBytesInUse == 0)
            return first.tokens
        } catch {
            await engine.shutdown()
            await store.closeAndWait()
            throw error
        }
    }

    @Test("real native pages and recurrent state survive encrypted donation, reopen and negative lookup",
        .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_BONSAI2_LIVE_MODEL"] != nil))
    func encryptedFullModelCheckpoint() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["DARKBLOOM_BONSAI2_LIVE_MODEL"])
        try #require(ProcessInfo.processInfo.environment["DARKBLOOM_BONSAI2_EXCLUSIVE_GPU"] == "1")
        _ = try #require(LiveInferenceFixtures.ensureMetallibColocated())
        let fixture = try Fixture()
        defer { fixture.removeGeneratedFiles() }
        Memory.cacheLimit = 1 << 30
        let container = try await VLMModelFactory.shared.loadContainer(
            from: URL(fileURLWithPath: path), using: LocalTokenizerLoader())
        let snapshot = await container.perform { context in
            EngineV2ModelSnapshot(model: context.model,
                eosTokenIds: context.configuration.eosTokenIds,
                extraEOSTokens: context.configuration.extraEOSTokens.sorted())
        }
        let tokenizer = await container.perform { TokenizerHandle($0.tokenizer) }
        let model = try #require(snapshot.model as? PrismHadamardQwen35)
        #expect(!model.cbv2Capabilities.supportsMTP)
        try await BonsaiMediaCohortQualification.run(container: container,
            model: model, tokenizer: tokenizer.inner)
        let scheduler = EngineV2Factory.productionSchedulerConfig(
            maxConcurrentRequests: 2, model: model, environment: ProcessInfo.processInfo.environment)
        let checkpointTokens = scheduler.soloPrefillStripeTokens ?? scheduler.prefillChunkSize
        // Select a positive full-stripe donor under the actual production
        // geometry. A shorter tail cannot provide a completed recurrent stripe.
        try #require(checkpointTokens == 2048, "fixture read bound is qualified for the default production stripe")
        let reference = try await runRound(model: model, tokenizer: tokenizer.inner,
            store: fixture.store(), checkpointTokens: checkpointTokens, expected: nil, reopened: false)
        try #require(!fixture.checkpointFiles().isEmpty)
        let reopened = fixture.store()
        _ = try await runRound(model: model, tokenizer: tokenizer.inner,
            store: reopened, checkpointTokens: checkpointTokens, expected: reference, reopened: true)
        print("BONSAI_ENCRYPTED_CHECKPOINT reopen_phase_completed; framework assertions determine verdict")

        // Only corrupt ciphertext generated by this test under its owned UUID
        // root. Production roots, weights and credentials are never touched.
        for file in try fixture.checkpointFiles() {
            var bytes = try Data(contentsOf: file)
            try #require(!bytes.isEmpty)
            bytes[bytes.count - 1] ^= 1
            try bytes.write(to: file)
        }
        let damaged = fixture.store()
        let built = try EngineV2Factory.makeProductionBuild(model: model,
            modelID: "ternary-bonsai-2-27b", tokenizer: tokenizer.inner,
            kvBytesCapacity: 4 << 30, maxConcurrentRequests: 1,
            completePrefixCache: damaged, kvBackend: .paged, maxContextLength: 8192)
        let engine = try #require(built.engine as? EngineV2)
        let request = CBv2Request(id: .init(21), promptTokens: (0..<(checkpointTokens + 7)).map { 37 + $0 % 500 },
            sampling: .init(temperature: 0), maxTokens: 16, cacheSalt: "synthetic-tenant-a",
            prefixCacheReceiptID: .init(201))
        do {
            let bad = await stage(damaged, engine: engine, request: request)
            #expect(!bad.staged && bad.disposition == .missCorrupt)
            let recomputed = await Self.collect(try engine.submit(request))
            try await BonsaiNativeFixtureDrain.require(engine)
            #expect(recomputed.tokens == reference && recomputed.finish == .length)
            #expect(recomputed.usage?.prefixCachePrefillTokensSaved == 0)
            await engine.shutdown()
            await damaged.closeAndWait()
            #expect(damaged.stats().stagedBytesInUse == 0)
            print("BONSAI_ENCRYPTED_CHECKPOINT corruption_phase_completed; framework assertions determine verdict")
        } catch {
            await engine.shutdown()
            await damaged.closeAndWait()
            throw error
        }
    }
}
