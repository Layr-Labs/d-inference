import CryptoKit
import Foundation
import MLX
import MLXLLM
@testable import MLXLMCommon
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

/// Real Qwen3.5-9B weights on the production paged assembly, with the
/// recurrent complete-checkpoint store. Only the cache root, the installation
/// key and the solo stripe are test-owned: the stripe is pinned to 2,048
/// tokens (dense Qwen defaults to 4,096) so a prompt under 10k tokens has
/// several chunk ends to retain. The catalog `-mtp` artifact's embedded MTP
/// head is served through the production inline assistant when it loads, so
/// checkpoints carry MTP history as in production; `mtpActive` says so.
final class Qwen35CheckpointRetentionFixture: @unchecked Sendable {
    /// `DARKBLOOM_LIVE_MLX_QWEN_RETENTION_MODEL` points the dense runs at
    /// another `qwen3_5` checkpoint in the cache (Qwen3.8-27B shares the
    /// architecture: 48 GDN + 16 full-attention layers, embedded MTP head).
    static let modelID = ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_QWEN_RETENTION_MODEL"]
        ?? "EigenLabs/Qwen3.5-9B-MLX-4bit-mtp"
    /// The MoE sibling for the partition sanity run: 35B-A3B, 40 layers,
    /// 256 experts. `DARKBLOOM_LIVE_MLX_QWEN_MOE_MODEL` selects another
    /// `qwen3_5_moe` checkpoint (Qwen3.5-35B-A3B is the same architecture).
    static let moeModelID = ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_QWEN_MOE_MODEL"]
        ?? "EigenLabs/Qwen3.6-35B-A3B-MLX-VL-4bit-g64-router8"
    /// `DARKBLOOM_LIVE_MLX_QWEN_RETENTION_BUDGET_GIB` widens the dense runs'
    /// slot budget for the larger checkpoints.
    static let denseBudgetBytes = (Int(ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_QWEN_RETENTION_BUDGET_GIB"] ?? "") ?? 32) << 30
    static let stripeTokens = 2_048
    let modelID: String
    let modelType: String
    let container: ModelContainer
    let model: Qwen35Model
    let assistant: Qwen35InlineMTPAssistant?
    var mtpActive: Bool { assistant != nil }
    let tokenizer: TokenizerHandle
    let eos: Set<Int>
    let extraEOSTokens: [String]
    let modelHash: String
    let prompts: Prompts
    let root: URL
    let key = SymmetricKey(size: .bits256)
    let identity: CBv2CompleteCheckpointIdentity
    private var bridges: [EngineV2Bridge] = []
    private var stores: [SSDHybridCheckpointStore] = []

    struct Prompts {
        /// Past 8,192 tokens: chunk ends at 2,048, 4,096, 6,144 and 8,192.
        let donor: [Int]
        /// The donor's records, for prompts that share only part of it.
        let records: [String]
    }

    static let releaseQuestion = "What is the release marker given at the beginning?"
    static let backupQuestion = "What is the backup marker given at the beginning?"
    static let instruction = " Reply with that marker only; do not include the other marker."
    static let releaseMarker = "ALDER-427"
    static let backupMarker = "BRONZE-913"

    static func sharedPrefix(_ lhs: [Int], _ rhs: [Int]) -> Int {
        zip(lhs, rhs).prefix { $0 == $1 }.count
    }

    func tokenize(_ messages: [[String: String]]) throws -> [Int] {
        try tokenizer.inner.applyChatTemplate(
            messages: messages, tools: nil, additionalContext: ["enable_thinking": false])
    }

    /// A different prompt that shares only the donor's opening records: its
    /// common prefix with the donor lands in `[minimum, minimum + 512)`, and
    /// it diverges well before the next chunk end.
    func forkPrompt(sharingAtLeast minimum: Int) throws -> (tokens: [Int], shared: Int) {
        for count in 1 ..< prompts.records.count {
            var records = Array(prompts.records.prefix(count))
            for index in 0 ..< 16 {
                records.append("Entry \(index): depot \(index % 11) filed an unrelated shipping note. The manifest was countersigned, the pallet count was reconciled, and the customs hold remains pending rather than released.")
            }
            let tokens = try tokenize([["role": "user", "content":
                records.joined(separator: "\n") + "\n" + Self.backupQuestion + Self.instruction]])
            let shared = Self.sharedPrefix(tokens, prompts.donor)
            guard shared >= minimum else { continue }
            try #require(shared < minimum + 512 && tokens.count > shared + 256,
                         "fork prompt must diverge shortly after the fork boundary")
            return (tokens, shared)
        }
        throw FixtureFailure.promptTooShort
    }

    /// A shorter donor built from the same records: its deepest chunk end is
    /// one chunk above the 4,096 fork target.
    func shortDonor(deepest: Int) throws -> [Int] {
        for count in stride(from: prompts.records.count, to: 0, by: -1) {
            let tokens = try tokenize([["role": "user", "content":
                prompts.records.prefix(count).joined(separator: "\n") + "\n" + Self.releaseQuestion + Self.instruction]])
            if tokens.count >= deepest + 64, tokens.count < deepest + Self.stripeTokens {
                return tokens
            }
        }
        throw FixtureFailure.promptTooShort
    }

    /// The donor's next turn: the whole donor prompt, its answer and a new
    /// question. The template renders the past turn without a generation
    /// prompt, so the shared prefix ends a few tokens short of the donor.
    func continuation() throws -> (tokens: [Int], shared: Int) {
        let messages: [[String: String]] = [
            ["role": "user", "content": prompts.records.joined(separator: "\n") + "\n"
                + Self.releaseQuestion + Self.instruction],
            ["role": "assistant", "content": Self.releaseMarker],
            ["role": "user", "content": Self.backupQuestion + Self.instruction],
        ]
        let tokens = try tokenize(messages)
        return (tokens, Self.sharedPrefix(tokens, prompts.donor))
    }

    init(modelID: String = Qwen35CheckpointRetentionFixture.modelID,
         memoryBudgetBytes: Int = Qwen35CheckpointRetentionFixture.denseBudgetBytes) async throws {
        self.modelID = modelID
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        guard case .found(let directory) = LiveInferenceFixtures.locate(modelID) else {
            throw LiveFixtureSkip.modelNotInCache(modelID)
        }
        modelType = LiveInferenceFixtures.modelTypeFromConfig(directory: directory) ?? "qwen3_5"
        modelHash = try #require(WeightHasher.computeHash(snapshotDir: directory, modelID: modelID))
        identity = CBv2CompleteCheckpointIdentity(
            modelAggregateHash: modelHash, promptContractID: "qwen35-checkpoint-retention-live-v1",
            buildID: "gated-live-test", numericsFingerprint: "paged-default-test-v1")
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: memoryBudgetBytes)
        container = try await ModelContainerLoading.loadContainer(from: directory, modelID: modelID)
        let snapshot = await container.perform { context in
            EngineV2ModelSnapshot(model: context.model, eosTokenIds: context.configuration.eosTokenIds,
                                 extraEOSTokens: context.configuration.extraEOSTokens.sorted())
        }
        // A catalog artifact that advertises media loads as the VLM wrapper;
        // production serves its text tower through the same extraction the
        // slot factory uses. A `language_model_only` artifact (Qwen3.8-27B)
        // loads as the text model directly and needs no extraction.
        if let direct = snapshot.model as? Qwen35Model {
            model = direct
        } else {
            let extraction = try EngineV2VLMTextExtraction.extractTextModel(
                from: snapshot.model, modelDirectory: directory)
            model = try #require(extraction.servingModel as? Qwen35Model,
                                 "the artifact must serve as a Qwen3.5-family text target (dense or MoE)")
        }
        try #require(model.cbv2Capabilities.supportsRecurrentCheckpointReuse)
        // An artifact that declares an embedded MTP head (`mtplx_mtp` in
        // config.json, as the default `-mtp` catalog build does) must load
        // it: a silent fallback would turn the MTP-history capture and
        // restore this suite claims into an MTP-off run. Only an artifact
        // without a declared head serves MTP-off.
        if Self.declaresEmbeddedMTPHead(directory: directory) {
            assistant = try Qwen35InlineMTPAssistant.load(from: directory, target: model)
        } else {
            print("[qwen35-retention] \(modelID) declares no embedded MTP head, serving MTP-off")
            assistant = nil
        }
        let resolvedTokenizer = await container.perform { TokenizerHandle($0.tokenizer) }
        tokenizer = resolvedTokenizer
        eos = ModelEOSPolicy.effectiveEOSTokenIds(
            modelId: modelID, modelType: modelType, base: snapshot.eosTokenIds,
            tokenToId: { resolvedTokenizer.inner.convertTokenToId($0) })
        extraEOSTokens = snapshot.extraEOSTokens
        prompts = try Self.makePrompts(resolvedTokenizer)
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("qwen35-checkpoint-retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Whether config.json carries the `mtplx_mtp` block the inline assistant
    /// loads from. Unreadable config counts as no head.
    static func declaresEmbeddedMTPHead(directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return root["mtplx_mtp"] != nil
    }

    private static func makePrompts(_ tokenizer: TokenizerHandle) throws -> Prompts {
        func tokenize(_ records: [String]) throws -> [Int] {
            try tokenizer.inner.applyChatTemplate(messages: [["role": "user", "content":
                records.joined(separator: "\n") + "\n" + releaseQuestion + instruction]],
                tools: nil, additionalContext: ["enable_thinking": false])
        }
        var records = ["The release marker is \(releaseMarker). The backup marker is \(backupMarker). Preserve both exactly."]
        for batch in 0 ..< 20 {
            for index in 0 ..< 20 {
                let n = batch * 20 + index
                records.append("Record \(n): station \(n % 17) reported a routine inspection. The reservoir gauge was checked, the inlet valve was serviced, and the next maintenance review remains proposed rather than approved.")
            }
            let donor = try tokenize(records)
            // Past 8,192 by a margin that survives the continuation's shorter
            // shared prefix, and short of the next chunk end.
            if donor.count >= 8_192 + 256 {
                try #require(donor.count < 8_192 + stripeTokens, "bounded prompt construction exceeded its limit")
                return Prompts(donor: donor, records: records)
            }
        }
        throw FixtureFailure.promptTooShort
    }

    func makeStore() throws -> SSDHybridCheckpointStore {
        let layout = CBv2CompleteCheckpointManifest.pagedLayout
        let name = SSDHybridCheckpointStoreFactory.namespace(
            modelId: modelID, identity: identity, backendLayout: layout)
        let modelRoot = root.appendingPathComponent(name)
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
        let fingerprint = Data(HMAC<SHA256>.authenticationCode(
            for: Data("darkbloom-cache-epoch-key-binding-v1".utf8), using: key)).hexString
        let epoch = try SSDCacheEpochStore(root: modelRoot, binding: .init(
            modelId: modelID, modelAggregateHash: identity.modelAggregateHash,
            promptContractId: identity.promptContractID, blockHashVersion: CBv2BlockHasher.version,
            blockSize: PrefixCachePolicy.blockSize,
            layoutEpoch: SSDHybridCheckpointEnvelope.layoutEpoch(identity: identity, backendLayout: layout),
            keyFingerprint: fingerprint))
        let store = SSDHybridCheckpointStore(config: .init(
            modelId: modelID, identity: identity, backendLayout: layout,
            root: modelRoot, dedicatedRoot: root, epochStore: epoch,
            maxReadBytes: SSDPrefixCachePolicy.maxStageBytes(environment: [:]),
            maxStageMillis: SSDPrefixCachePolicy.maxStageMillis(environment: [:]),
            minEffectiveTokens: SSDPrefixCachePolicy.minEffectiveTokens(environment: [:]),
            ttlSeconds: SSDPrefixCachePolicy.ttlSeconds(environment: [:]), strictFsync: false,
            nowSeconds: { Int64(Date().timeIntervalSince1970) }, diskBudgetBytes: { 8 << 30 },
            maintainWholeRoot: {}), kekKey: key, kvBudget: nil,
            maxWriteBytesPerDay: SSDPrefixCachePolicy.defaultMaxWriteBytesPerDay,
            usesEphemeralKey: true)
        stores.append(store)
        store.scanOnDisk()
        return store
    }

    func makeBridge(store: SSDHybridCheckpointStore?, maxConcurrentRequests: Int = 1) throws -> EngineV2Bridge {
        var environment = ["DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE": String(Self.stripeTokens)]
        if store == nil { environment["DARKBLOOM_PREFIX_CACHE"] = "0" }
        // `.auto` maps catalog IDs to paged; this dev artifact is not listed,
        // so select the native paged backend production uses for the family.
        let build = try EngineV2Factory.makeProductionBuild(
            model: model, modelID: modelID, tokenizer: tokenizer.inner,
            kvBytesCapacity: 16 << 30, maxConcurrentRequests: maxConcurrentRequests,
            completePrefixCache: store, mtpDrafter: assistant,
            mtpConfig: assistant == nil ? CBv2MTPConfig() : .init(
                enabled: true, maxDraftTokens: CBv2MTPConfig.testedMaxDraftTokens, verificationMode: .rectangular),
            kvBackend: .paged, environment: environment)
        try #require(build.kvBackendKind == .paged && build.kvBackendFallbackReason == nil,
                     "dense Qwen3.5 serving must resolve to native paged KV without fallback")
        if store != nil {
            let engine = try #require(build.engine as? EngineV2)
            try #require(engine.completeCheckpointCodec?.backendLayout == CBv2CompleteCheckpointManifest.pagedLayout,
                         "the store layout must be the codec's")
            try #require(engine.loopForTesting.scheduler.config.soloPrefillStripeTokens == Self.stripeTokens)
        }
        let bridge = EngineV2Bridge(engine: build.engine, modelId: modelID,
            tokenizer: tokenizer, eosTokenIds: eos, extraEOSTokens: extraEOSTokens,
            maxConcurrentRequests: maxConcurrentRequests, fixedRequestBytes: build.fixedRequestBytes,
            ssdHybridCheckpointStore: store, kvBackendKind: .paged)
        bridges.append(bridge)
        return bridge
    }

    /// A short question that decodes long at temperature 0, to keep a
    /// decode row alive beside a prefilling donor.
    func companionPrompt() throws -> [Int] {
        try tokenize([["role": "user", "content":
            "Write a long, detailed essay about the history of harbours, one paragraph per century, "
            + "from antiquity to the present day. Do not stop early."]])
    }

    /// Geometry records the engine's capture pass saw for `promptLength`
    /// tokens of one request: (range, planned cap, outcome).
    final class GeometryTrace: @unchecked Sendable {
        struct Record { let range: Range<Int>; let cap: Int; let outcome: String }
        private let lock = NSLock()
        private var records: [UInt64: [Record]] = [:]
        func append(_ id: UInt64, range: Range<Int>, cap: Int, outcome: String) {
            lock.lock(); records[id, default: []].append(.init(range: range, cap: cap, outcome: outcome)); lock.unlock()
        }
        func records(promptLength: Int) -> [Record] {
            lock.lock(); defer { lock.unlock() }
            // The donor is the request whose records reach that many tokens.
            return records.values.first { $0.contains { $0.range.upperBound == promptLength } }?
                .filter { $0.range.upperBound <= promptLength } ?? []
        }
    }

    /// Install the engine's geometry observer on a bridge's engine.
    func observeGeometry(_ bridge: EngineV2Bridge) async throws -> GeometryTrace {
        let engine = try #require(await bridge.engine as? EngineV2)
        let trace = GeometryTrace()
        engine.loopForTesting.onEngineQueueSync {
            engine.loopForTesting.recurrentGeometryObserverForTesting = { id, range, cap, _, phase, outcome in
                guard phase == "record" else { return }
                trace.append(id.raw, range: range, cap: cap ?? -1, outcome: outcome)
            }
        }
        return trace
    }

    /// Computed prompt tokens of the running request with `promptLength`
    /// prompt tokens, or nil while it is not running.
    func computedTokens(_ bridge: EngineV2Bridge, promptLength: Int) async throws -> Int? {
        let engine = try #require(await bridge.engine as? EngineV2)
        return engine.loopForTesting.onEngineQueueSync {
            engine.loopForTesting.scheduler.running
                .first { $0.request.promptTokens.count == promptLength }?.numComputedTokens
        }
    }

    /// Authenticate every encrypted segment, retaining only the small manifest.
    func persistedManifests() throws -> [CBv2CompleteCheckpointManifest] {
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "dbk3" }
        try #require(!files.isEmpty, "no encrypted complete-checkpoint files found")
        return try files.map { file in
            var manifestBytes: Data?
            try SSDBlockStore.readStreaming(from: file, kekKey: key,
                maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
                maximumPlaintextBytes: SSDPrefixCachePolicy.maxStageBytes(environment: [:]),
                requireEOF: true, validateMetadata: { _ in },
                consumeChunk: { index, data in if index == 0 { manifestBytes = data } })
            let manifest = try SSDHybridCheckpointEnvelope.decodeManifest(try #require(manifestBytes))
            #expect(manifest.identity == identity)
            #expect(manifest.backendLayout == CBv2CompleteCheckpointManifest.pagedLayout)
            #expect(manifest.cacheSalt?.hasPrefix("tenant-") == true)
            #expect(manifest.position % PrefixCachePolicy.blockSize == 0 && manifest.chunkSize > 0,
                    "recurrent boundaries sit on the block-hash stride; chunkSize is the chunk that ended there")
            return manifest
        }
    }

    /// Retained boundaries of one scope that prefix `tokens`, ascending, with
    /// the packed tensor bytes of each file.
    func positions(scope: String, prefixOf tokens: [Int]) throws -> (positions: [Int], bytes: [Int]) {
        let manifests = try persistedManifests()
            .filter { $0.cacheSalt == scope && tokens.starts(with: $0.prefixTokens) }
            .sorted { $0.position < $1.position }
        return (manifests.map(\.position), manifests.map { $0.tensors.reduce(0) { $0 + $1.byteCount } })
    }

    func close() async {
        for bridge in bridges { await bridge.shutdown() }
        bridges.removeAll()
        for store in stores { await store.closeAndWait() }
        stores.removeAll()
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Qwen3.5 retention fixture cleanup failed: \(error)") }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        MLX.Memory.clearCache()
    }

    enum FixtureFailure: Error { case promptTooShort }
}
