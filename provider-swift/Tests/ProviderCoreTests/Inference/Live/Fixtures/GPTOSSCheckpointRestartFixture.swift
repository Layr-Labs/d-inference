import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

/// Exact catalog weights and production paged assembly. Only the cache root and
/// installation key are test-owned; this proves engine reconstruction, not
/// keychain recovery or a provider-process restart.
final class GPTOSSCheckpointRestartFixture: @unchecked Sendable {
    static let modelID = "gpt-oss-20b"
    static let upstreamModelID = "mlx-community/gpt-oss-20b-MXFP4-Q8"
    static let modelHash = "61bfc04e4016a7fa487eb10e29f79360047e302487229f298da3681984aec512"
    let container: ModelContainer
    let model: GPTOSSModel
    let tokenizer: TokenizerHandle
    let eos: Set<Int>
    let extraEOSTokens: [String]
    let prompts: Prompts
    let root: URL
    let key = SymmetricKey(size: .bits256)
    let identity = CBv2CompleteCheckpointIdentity(
        modelAggregateHash: GPTOSSCheckpointRestartFixture.modelHash,
        promptContractID: "gptoss-checkpoint-restart-live-v1",
        buildID: "gated-live-test", numericsFingerprint: "paged-default-test-v1")
    private var bridges: [EngineV2Bridge] = []
    private var stores: [SSDHybridCheckpointStore] = []

    struct Prompts {
        let donor: [Int]
        let branch: [Int]
        let changedPrefix: [Int]
        /// The donor's records, for prompts that share only part of it.
        let records: [String]
    }

    static let releaseQuestion = "What is the release marker given at the beginning?"
    static let backupQuestion = "What is the backup marker given at the beginning?"
    static let instruction = " Reply with that marker only; do not include the other marker."

    struct Conversation {
        /// The turn a cold provider serves first, and the turn after it.
        let second: [Int]
        let third: [Int]
        /// Tokens the previous turn's prompt shares with each of them: what
        /// the coordinator's repeat observation would be built from.
        let sharedWithFirst: Int
        let sharedWithSecond: Int
    }

    static func sharedPrefix(_ lhs: [Int], _ rhs: [Int]) -> Int {
        zip(lhs, rhs).prefix { $0 == $1 }.count
    }

    func tokenize(_ messages: [[String: String]]) throws -> [Int] {
        try tokenizer.inner.applyChatTemplate(messages: messages, tools: nil,
                                              additionalContext: ["reasoning_effort": "low"])
    }

    /// A different prompt that shares only the donor's opening records: its
    /// common prefix with the donor lands in `[minimum, minimum + 512)`.
    func forkPrompt(sharingAtLeast minimum: Int) throws -> (tokens: [Int], shared: Int) {
        for count in 1 ..< prompts.records.count {
            var records = Array(prompts.records.prefix(count))
            for index in 0 ..< 24 {
                records.append("Entry \(index): depot \(index % 11) filed an unrelated shipping note. The manifest was countersigned, the pallet count was reconciled, and the customs hold remains pending rather than released.")
            }
            let tokens = try tokenize([["role": "user", "content":
                records.joined(separator: "\n") + "\n" + Self.backupQuestion + Self.instruction]])
            let shared = Self.sharedPrefix(tokens, prompts.donor)
            guard shared >= minimum else { continue }
            try #require(shared < minimum + 512 && tokens.count > shared + 512,
                         "fork prompt must diverge shortly after the fork boundary")
            return (tokens, shared)
        }
        throw FixtureFailure.promptTooShort
    }

    /// Three turns of one growing conversation. The first turn is never
    /// served here; it only defines what the second turn shares with it.
    func conversation() throws -> Conversation {
        let half = prompts.records.count / 2
        let opening = prompts.records.prefix(half).joined(separator: "\n") + "\n"
            + Self.releaseQuestion + Self.instruction
        let followUp = "More records follow.\n" + prompts.records.dropFirst(half).joined(separator: "\n")
            + "\n" + Self.backupQuestion + Self.instruction
        let first: [[String: String]] = [["role": "user", "content": opening]]
        let second = first + [["role": "assistant", "content": "ALDER-427"],
                              ["role": "user", "content": followUp]]
        let third = second + [["role": "assistant", "content": "BRONZE-913"],
                              ["role": "user", "content": Self.releaseQuestion + Self.instruction]]
        let tokens = (first: try tokenize(first), second: try tokenize(second), third: try tokenize(third))
        try #require(tokens.second.count >= 6_144 + 64 && tokens.third.count < 8_192,
                     "conversation prompts left the fixture's bounds: \(tokens.second.count), \(tokens.third.count)")
        return Conversation(second: tokens.second, third: tokens.third,
                            sharedWithFirst: Self.sharedPrefix(tokens.first, tokens.second),
                            sharedWithSecond: Self.sharedPrefix(tokens.second, tokens.third))
    }

    init() async throws {
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        let directory: URL
        if let path = ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GPTOSS_MODEL_DIRECTORY"],
           !path.isEmpty {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else if case .found(let cached) = LiveInferenceFixtures.locate(Self.modelID) {
            directory = cached
        } else if case .found(let cached) = LiveInferenceFixtures.locate(Self.upstreamModelID) {
            directory = cached
        } else {
            throw LiveFixtureSkip.modelNotInCache(Self.upstreamModelID)
        }
        let before = WeightHasher.computeHash(snapshotDir: directory, modelID: Self.modelID)
        try #require(before == Self.modelHash, "live fixture requires the exact GPT-OSS-20B catalog artifact")
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 48 << 30)
        container = try await LLMModelFactory.shared.loadContainer(
            from: directory, using: LocalTokenizerLoader())
        try #require(WeightHasher.computeHash(snapshotDir: directory, modelID: Self.modelID) == before)
        let snapshot = await container.perform { context in
            EngineV2ModelSnapshot(model: context.model, eosTokenIds: context.configuration.eosTokenIds,
                                 extraEOSTokens: context.configuration.extraEOSTokens.sorted())
        }
        model = try #require(snapshot.model as? GPTOSSModel)
        try #require(model.cbv2SupportsHistoricalAttentionCheckpoint)
        let resolvedTokenizer = await container.perform { TokenizerHandle($0.tokenizer) }
        tokenizer = resolvedTokenizer
        eos = ModelEOSPolicy.effectiveEOSTokenIds(
            modelId: Self.modelID, modelType: "gpt_oss", base: snapshot.eosTokenIds,
            tokenToId: { resolvedTokenizer.inner.convertTokenToId($0) })
        extraEOSTokens = snapshot.extraEOSTokens
        prompts = try Self.makePrompts(resolvedTokenizer)
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("gptoss-checkpoint-restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private static func makePrompts(_ tokenizer: TokenizerHandle) throws -> Prompts {
        func tokenize(_ records: [String], question: String) throws -> [Int] {
            try tokenizer.inner.applyChatTemplate(messages: [["role": "user", "content":
                records.joined(separator: "\n") + "\n" + question
                    + " Reply with that marker only; do not include the other marker."]],
                tools: nil, additionalContext: ["reasoning_effort": "low"])
        }
        var records = ["The release marker is ALDER-427. The backup marker is BRONZE-913. Preserve both exactly."]
        for batch in 0..<12 {
            for index in 0..<20 {
                let n = batch * 20 + index
                records.append("Record \(n): station \(n % 17) reported a routine inspection. The reservoir gauge was checked, the inlet valve was serviced, and the next maintenance review remains proposed rather than approved.")
            }
            let donor = try tokenize(records, question: "What is the release marker given at the beginning?")
            if donor.count >= 6_144 {
                let branch = try tokenize(records, question: "What is the backup marker given at the beginning?")
                let donorRecords = records
                records[0] = "The release marker is ALDER-427. The backup marker is CEDAR-682. Preserve both exactly."
                let changed = try tokenize(records, question: "What is the backup marker given at the beginning?")
                try #require(max(donor.count, branch.count, changed.count) < 8_192,
                             "bounded prompt construction exceeded its limit")
                return Prompts(donor: donor, branch: branch, changedPrefix: changed, records: donorRecords)
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

    func makeBridge(store: SSDHybridCheckpointStore?, maxConcurrentRequests: Int = 1) throws -> EngineV2Bridge {
        try #require(PrefixCachePolicy.isEnabled(modelId: Self.modelID, environment: [:]),
                     "the exact catalog model must activate caching without an opt-in")
        #expect(!PrefixCachePolicy.isMemoryEnabled(environment: [:]))
        let build = try EngineV2Factory.makeProductionBuild(
            model: model, modelID: Self.modelID, tokenizer: tokenizer.inner,
            kvBytesCapacity: 16 << 30, maxConcurrentRequests: maxConcurrentRequests,
            completePrefixCache: store, kvBackend: .auto,
            environment: store == nil ? ["DARKBLOOM_PREFIX_CACHE": "0"] : [:])
        try #require(build.kvBackendKind == .paged && build.kvBackendFallbackReason == nil,
                     "default GPT-OSS serving must resolve to paged without fallback")
        let bridge = EngineV2Bridge(engine: build.engine, modelId: Self.modelID,
            tokenizer: tokenizer, eosTokenIds: eos, extraEOSTokens: extraEOSTokens,
            maxConcurrentRequests: maxConcurrentRequests, fixedRequestBytes: build.fixedRequestBytes,
            ssdHybridCheckpointStore: store, kvBackendKind: .paged)
        bridges.append(bridge)
        return bridge
    }

    /// Authenticate every encrypted segment, retaining only the small manifest.
    /// This avoids loading an entire checkpoint into an unbounded host buffer.
    func persistedManifests() throws -> [CBv2CompleteCheckpointManifest] {
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "dbk3" }
        try #require(!files.isEmpty, "no encrypted complete-checkpoint files found")
        let sample = try #require(files.first)
        #expect(throws: (any Error).self) {
            try SSDBlockStore.readStreaming(from: sample, kekKey: SymmetricKey(size: .bits256),
                maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
                maximumPlaintextBytes: SSDPrefixCachePolicy.maxStageBytes(environment: [:]),
                validateMetadata: { _ in }, consumeChunk: { _, _ in })
        }
        return try files.map { file in
            var manifestBytes: Data?
            try SSDBlockStore.readStreaming(from: file, kekKey: key,
                maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
                maximumPlaintextBytes: SSDPrefixCachePolicy.maxStageBytes(environment: [:]),
                requireEOF: true, validateMetadata: { _ in },
                consumeChunk: { index, data in if index == 0 { manifestBytes = data } })
            let manifest = try SSDHybridCheckpointEnvelope.decodeManifest(try #require(manifestBytes))
            #expect(manifest.identity == identity)
            #expect(manifest.backendLayout == CBv2CompleteCheckpointManifest.historicalAttentionLayout)
            #expect(manifest.cacheSalt?.hasPrefix("tenant-") == true)
            #expect(manifest.position % 1024 == 0 && manifest.chunkSize == 1024,
                    "historical manifests carry the capture stride as their alignment")
            let layers = try #require(manifest.attentionLayers)
            #expect(layers.count == model.cbv2LayerKinds.count)
            #expect(layers.contains { $0.window == 128 })
            #expect(layers.contains { $0.window == nil })
            #expect(layers.allSatisfy { $0.hasSinks }, "real GPT-OSS learned attention sinks must be represented")
            return manifest
        }
    }

    func close() async {
        for bridge in bridges { await bridge.shutdown() }
        bridges.removeAll()
        for store in stores { await store.closeAndWait() }
        stores.removeAll()
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("GPT-OSS restart fixture cleanup failed: \(error)") }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    enum FixtureFailure: Error { case promptTooShort }
}
