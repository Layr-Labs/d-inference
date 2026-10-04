import CryptoKit
import Foundation
import MLX
@testable import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

/// Receipt wiring is host-only: the real store's admission and priority
/// consumers run without constructing checkpoint arrays or evaluating Metal.
@Suite("Benchmark session donation demand", .serialized)
struct BenchmarkSessionDonationDemandTests {
    @Test("nil, novel and covered-repeat inputs retain different write policies")
    func scopedDemandPolicy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store
        let samplingID = CBv2RequestID(8)
        for (offset, hint) in [nil, 0, 2_048].enumerated() {
            let receipt = CBv2RequestID(UInt64(100 + offset))
            let request = CBv2Request(id: samplingID, promptTokens: [1, 2, 3],
                maxTokens: 1, cacheSalt: "tenant", prefixCheckpointTargetTokens: hint)
            EngineV2BenchmarkSession.registerDonationDemand(
                for: request, receiptID: receipt, store: store)
            let covered = store.donationWritePolicy(requestID: receipt,
                localRepeat: false, checkpointPosition: 1_024)
            #expect(covered.refusal == (hint == 0 ? .skippedNovel : nil))
            #expect(covered.repeated == (hint == 2_048))
            let extensionPolicy = store.donationWritePolicy(requestID: receipt,
                localRepeat: false, checkpointPosition: 3_072)
            #expect(!extensionPolicy.repeated, "a unique suffix must not spend repeat priority")
            #expect(store.donationDemandHints.demand(for: samplingID) == nil,
                "reused sampling IDs are not submission receipts")
        }
        #expect(store.donationDemandHints.count == 2, "nil creates no demand record")
        await store.closeAndWait()
        #expect(store.donationDemandHints.count == 0)
    }

    @Test("disabled or unscoped inputs cannot manufacture fleet repetition")
    func excludedInputs() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for (offset, pair) in [(false, "tenant"), (true, "")].enumerated() {
            let receipt = CBv2RequestID(UInt64(200 + offset))
            let request = CBv2Request(id: .init(8), promptTokens: [1, 2, 3],
                maxTokens: 1, cacheSalt: pair.1, prefixCacheEnabled: pair.0,
                prefixCheckpointTargetTokens: 2_048)
            EngineV2BenchmarkSession.registerDonationDemand(
                for: request, receiptID: receipt, store: fixture.store)
            #expect(fixture.store.donationDemandHints.demand(for: receipt) == nil)
            #expect(!fixture.store.donationWritePolicy(requestID: receipt,
                localRepeat: false, checkpointPosition: 1_024).repeated)
        }
        await fixture.store.closeAndWait()
    }

    @Test("actual submit refusal retires donation metadata with its fresh receipt")
    func submissionFailureClearsDemand() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = try makeSession(fixture, maxWaiting: 0)
        let request = CBv2Request(id: .init(8), promptTokens: [1, 2, 3], maxTokens: 1,
            cacheSalt: "tenant", prefixCheckpointTargetTokens: 2_048)
        for _ in 0 ..< 2 {
            await #expect(throws: (any Error).self) { try await session.submit(request) }
            #expect(fixture.store.donationDemandHints.count == 0,
                "failed submissions must not leak demand or their reusable engine ID")
            #expect(fixture.store.stats().stagedBytesInUse == 0)
        }
        await session.shutdown()
    }

    @Test("actual accepted submit registers scoped demand under its receipt and shutdown clears it")
    func acceptedSubmissionOwnsDemand() async throws {
        for hint in [nil, 0, 2_048] as [Int?] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let session = try makeSession(fixture, maxWaiting: 1, suspend: true)
            let request = CBv2Request(id: .init(8), promptTokens: [1, 2, 3], maxTokens: 1,
                cacheSalt: "tenant", prefixCheckpointTargetTokens: hint)
            let submission = try await session.submit(request)
            #expect(submission.receiptID != request.id)
            #expect(fixture.store.donationDemandHints.demand(for: submission.receiptID)?
                .repeatedPrefixTokens == hint,
                "the real submission must forward nil, explicit novel and repeat demand")
            #expect(fixture.store.donationDemandHints.demand(for: request.id) == nil)
            let policy = fixture.store.donationWritePolicy(requestID: submission.receiptID,
                localRepeat: false, checkpointPosition: 1_024)
            #expect(policy.refusal == (hint == 0 ? .skippedNovel : nil))
            #expect(policy.repeated == (hint == 2_048))
            await session.shutdown()
            #expect(fixture.store.donationDemandHints.count == 0)
            #expect(session.rawEngine.capacity().waitingRequests == 0)
        }
    }

    private func makeSession(_ fixture: Fixture, maxWaiting: Int,
                             suspend: Bool = false) throws -> EngineV2BenchmarkSession {
        let kinds = [CBv2LayerKind(attention: .full, headDim: 64, valueHeadDim: 32,
                                 kvHeads: 1, queryHeads: 1)]
        let engine = EngineV2(model: NeverForward(), layerKinds: kinds,
            backend: CBv2ContiguousKVBackend(config: .init(bytesCapacity: 1 << 20,
                                                        kvDType: .float32)),
            cacheProvider: CBv2LayerCacheBank(layerKinds: kinds),
            schedulerConfig: .init(maxWaiting: maxWaiting, enablePrefixCache: true),
            completePrefixCache: fixture.store)
        try #require(engine.completePrefixCache === fixture.store,
            "the real engine must accept the same checkpoint store the bridge owns")
        if suspend {
            engine.loopForTesting.onEngineQueueSync {
                // Stop before markStepStarted/row construction/model forward;
                // enqueue and shutdown still use their actual host paths.
                engine.loopForTesting.suspendStepExecutionAtCountForTesting = 0
            }
        }
        let bridge = EngineV2Bridge(engine: engine, modelId: "benchmark-demand-fixture",
            tokenizer: TokenizerHandle(FixedTokenizer()), eosTokenIds: [],
            ssdHybridCheckpointStore: fixture.store)
        try #require(bridge.ssdHybridCheckpointStore === fixture.store && !fixture.store.isClosed,
            "a store rejected/closed by bridge construction cannot test submission hint wiring")
        return EngineV2BenchmarkSession(bundle: .init(targetOnly: bridge), engine: engine,
            backend: "contiguous", fallback: nil, effectiveMaxConcurrentRequests: 1,
            memoryEnabled: false, activationReserveBytes: 0, postLoadMaximumKVBytes: 1 << 20,
            budget: fixture.budget, assistantIdentity: [:], productionGrant: nil,
            postBuildHeadroomBytes: nil)
    }

    private final class Fixture {
        let root: URL
        let store: SSDHybridCheckpointStore
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30) })

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("benchmark-demand-\(UUID().uuidString)")
            let modelRoot = root.appendingPathComponent("0123456789ab")
            try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
            store = SSDHybridCheckpointStore(config: .init(modelId: "benchmark-demand-fixture",
                identity: .init(modelAggregateHash: "fixture", promptContractID: "fixture",
                    buildID: "fixture", numericsFingerprint: "fixture"),
                backendLayout: CBv2CompleteCheckpointManifest.contiguousAsymmetricLayout,
                root: modelRoot, dedicatedRoot: root, epochStore: nil,
                maxReadBytes: 1 << 20, maxStageMillis: 1_000, minEffectiveTokens: 1_024,
                ttlSeconds: 1_800, strictFsync: false, nowSeconds: { 1 },
                diskBudgetBytes: { 1 << 20 }, maintainWholeRoot: {}),
                kekKey: SymmetricKey(size: .bits256), kvBudget: budget,
                diskBudget: SSDDiskBudget(), maxWriteBytesPerDay: 0)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// Metadata-only codec qualification. The suspended host fixture never
    /// constructs tensors or claims native/model numerical qualification.
    private final class NeverForward: CBv2SteppableModel,
                                      CBv2HistoricalAttentionCheckpointProviding,
                                      CBv2CompleteCheckpointKVTypeProviding {
        var cbv2SupportsHistoricalAttentionCheckpoint: Bool { true }
        var cbv2CompleteCheckpointKVDTypes: [DType]? { [.float32] }
        func forward(tokens: MLXArray, caches: [CBv2AttendingLayerCache]) -> MLXArray {
            preconditionFailure("queue-full host fixture must never build a model graph")
        }
    }

    private struct FixedTokenizer: MLXLMCommon.Tokenizer {
        func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1] }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "fixture" }
        func convertTokenToId(_ token: String) -> Int? { nil }
        func convertIdToToken(_ id: Int) -> String? { nil }
        var bosToken: String? { nil }
        var eosToken: String? { nil }
        var unknownToken: String? { nil }
        func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?) throws -> [Int] { [1] }
    }
}
