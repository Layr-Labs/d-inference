import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

/// A real paged target with a test-owned key. It exercises encrypted complete
/// checkpoint persistence across engine reconstruction, not keychain recovery.
final class GemmaQATCheckpointRestartFixture {
    static let modelID = "gemma-4-26b-qat-4bit"
    static let modelHash = "2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785"
    let container: ModelContainer
    let model: any LanguageModel
    let tokenizer: TokenizerHandle
    let eos: Set<Int>
    let extraEOSTokens: [String]
    let tokens: [Int]
    let root: URL
    let key = SymmetricKey(size: .bits256)
    let identity = CBv2CompleteCheckpointIdentity(
        modelAggregateHash: GemmaQATCheckpointRestartFixture.modelHash, promptContractID: "gemma-qat-restart-live-v1",
        buildID: "gated-live-test", numericsFingerprint: "paged-target-only-test-v1")
    private var bridges: [EngineV2Bridge] = []
    private var stores: [SSDHybridCheckpointStore] = []

    init() async throws {
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        guard case .found(let directory) = LiveInferenceFixtures.locate(Self.modelID) else {
            throw LiveFixtureSkip.modelNotInCache(Self.modelID)
        }
        let before = WeightHasher.computeHash(snapshotDir: directory, modelID: Self.modelID)
        try #require(before == Self.modelHash, "live restart fixture requires the exact QAT artifact")
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 64 << 30)
        container = try await VLMModelFactory.shared.loadContainer(
            from: directory, using: LocalTokenizerLoader())
        try #require(WeightHasher.computeHash(snapshotDir: directory, modelID: Self.modelID) == before)
        let snapshot = await container.perform { context in
            EngineV2ModelSnapshot(model: context.model, eosTokenIds: context.configuration.eosTokenIds,
                                 extraEOSTokens: context.configuration.extraEOSTokens.sorted())
        }
        let wrapper = try #require(snapshot.model as? MLXVLM.Gemma4)
        model = try EngineV2Factory.directServingModel(model: wrapper, isVLM: true)
        try #require(ObjectIdentifier(model) == ObjectIdentifier(wrapper.textModel))
        let resolvedTokenizer = await container.perform { TokenizerHandle($0.tokenizer) }
        tokenizer = resolvedTokenizer
        eos = ModelEOSPolicy.effectiveEOSTokenIds(
            modelId: Self.modelID, modelType: "gemma4", base: snapshot.eosTokenIds,
            tokenToId: { resolvedTokenizer.inner.convertTokenToId($0) })
        extraEOSTokens = snapshot.extraEOSTokens
        tokens = try Self.makePrompt(tokenizer)
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("gemma-qat-checkpoint-restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private static func makePrompt(_ tokenizer: TokenizerHandle) throws -> [Int] {
        var records = ["The release marker is ALDER-427. Preserve the marker exactly."]
        for batch in 0..<12 {
            for index in 0..<20 {
                let n = batch * 20 + index
                records.append("Record \(n): station \(n % 17) reported a routine inspection. The reservoir gauge was checked, the inlet valve was serviced, and the next maintenance review remains proposed rather than approved.")
            }
            let text = records.joined(separator: "\n")
                + "\nWhat is the release marker given at the beginning? Reply with the marker only."
            let tokens = try tokenizer.inner.applyChatTemplate(
                messages: [["role": "user", "content": text]], tools: nil, additionalContext: ["enable_thinking": false])
            if tokens.count >= 6_144 {
                try #require(tokens.count < 8_192, "bounded prompt construction exceeded its limit")
                return tokens
            }
        }
        throw FixtureFailure.promptTooShort
    }

    func makeStore() throws -> SSDHybridCheckpointStore {
        let layout = CBv2CompleteCheckpointManifest.historicalAttentionLayout
        let name = SSDHybridCheckpointStoreFactory.namespace(
            modelId: Self.modelID, identity: identity, backendLayout: layout)
        let modelRoot = root.appendingPathComponent(name)
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
        let fingerprint = Data(HMAC<SHA256>.authenticationCode(
            for: Data("darkbloom-cache-epoch-key-binding-v1".utf8), using: key)).hexString
        let epoch = try SSDCacheEpochStore(root: modelRoot, binding: .init(
            modelId: Self.modelID, modelAggregateHash: identity.modelAggregateHash,
            promptContractId: identity.promptContractID, blockHashVersion: CBv2BlockHasher.version,
            blockSize: PrefixCachePolicy.blockSize,
            layoutEpoch: SSDHybridCheckpointEnvelope.layoutEpoch(identity: identity, backendLayout: layout),
            keyFingerprint: fingerprint))
        let store = SSDHybridCheckpointStore(config: .init(
            modelId: Self.modelID, identity: identity, backendLayout: layout,
            root: modelRoot, dedicatedRoot: root, epochStore: epoch,
            maxReadBytes: SSDPrefixCachePolicy.maxStageBytes(environment: [:]),
            maxStageMillis: SSDPrefixCachePolicy.maxStageMillis(environment: [:]),
            minEffectiveTokens: SSDPrefixCachePolicy.minEffectiveTokens(environment: [:]),
            ttlSeconds: SSDPrefixCachePolicy.ttlSeconds(environment: [:]), strictFsync: false,
            nowSeconds: { Int64(Date().timeIntervalSince1970) }, diskBudgetBytes: { 4 << 30 },
            maintainWholeRoot: {}), kekKey: key, kvBudget: nil,
            maxWriteBytesPerDay: SSDPrefixCachePolicy.defaultMaxWriteBytesPerDay,
            usesEphemeralKey: true)
        stores.append(store)
        store.scanOnDisk()
        return store
    }

    func makeBridge(store: SSDHybridCheckpointStore?) throws -> EngineV2Bridge {
        let build = try EngineV2Factory.makeProductionBuild(
            model: model, modelID: Self.modelID, tokenizer: tokenizer.inner,
            kvBytesCapacity: 24 << 30, maxConcurrentRequests: 1,
            completePrefixCache: store, kvBackend: .paged, environment: [:])
        try #require(build.kvBackendKind == .paged && build.kvBackendFallbackReason == nil)
        let bridge = EngineV2Bridge(engine: build.engine, modelId: Self.modelID,
            tokenizer: tokenizer, eosTokenIds: eos, extraEOSTokens: extraEOSTokens,
            maxConcurrentRequests: 1,
            fixedRequestBytes: build.fixedRequestBytes, ssdHybridCheckpointStore: store,
            kvBackendKind: .paged)
        bridges.append(bridge)
        return bridge
    }

    func close() async {
        for bridge in bridges { await bridge.shutdown() }
        bridges.removeAll()
        // A store can be created before bridge construction throws. Drain it
        // even when no bridge ever took ownership, before removing its files.
        for store in stores { await store.closeAndWait() }
        stores.removeAll()
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("restart fixture cleanup failed: \(error)") }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    enum FixtureFailure: Error { case promptTooShort }
}
