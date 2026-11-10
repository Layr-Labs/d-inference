import CryptoKit
import Foundation
import MLX
@testable import MLXLLM
@testable import MLXLMCommon
import MLXNN
import Testing

@testable import ProviderCore

/// The Qwen 3.5/3.6 builds' provider defaults (`EngineV2SamplingDefaults.qwen35CardDefaults`,
/// with its presence penalty of 1.5) keep a request that sends no sampling field from
/// speculating. On the production paged assembly, with the inline MTP assistant and the
/// encrypted complete-checkpoint store, such a request must still donate its prompt's
/// checkpoints, answer exactly as it does with the cache off, and let the next identical
/// request restore them and answer exactly as its cold run. Synthetic weights, no model load.
@Suite("Qwen 3.5 card-default requests donate SSD checkpoints", .serialized)
struct Qwen35CardDefaultDonationTests {
    enum Build: String, CaseIterable, CustomTestStringConvertible {
        /// `Qwen3.5-9B`: the dense target, with the provider's dense-Qwen checkpoint rules.
        case dense = "Qwen3.5-9B"
        /// `qwen3.5-35b-a3b`: routed quantized experts and a shared expert.
        case moe = "qwen3.5-35b-a3b"
        var testDescription: String { rawValue }
        var modelType: String { self == .moe ? "qwen3_5_moe" : "qwen3_5" }
    }

    /// What a client adds to the card's defaults.
    enum Extra: String, CaseIterable, CustomTestStringConvertible {
        case none, stop, logprobs
        var testDescription: String { rawValue }
    }

    static let stripe = 1_024
    static let prompt: [Int] = (0 ..< 2 * stripe + 300).map { 1 + ($0 * 7) % 61 }
    static let maxTokens = 16

    /// Decodes every id to its own text, so the streamed text names the tokens.
    struct IDTokenizer: MLXLMCommon.Tokenizer {
        func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            tokenIds.map { "<\($0)>" }.joined()
        }
        func convertTokenToId(_ token: String) -> Int? { nil }
        func convertIdToToken(_ id: Int) -> String? { "<\(id)>" }
        var bosToken: String? { nil }
        var eosToken: String? { nil }
        var unknownToken: String? { nil }
        func applyChatTemplate(
            messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] { prompt }
    }

    /// The production serving classes (`Qwen35Model`, `Qwen35MoEModel`) with the
    /// production-loaded inline assistant. One target for every engine of a test.
    static func target(_ build: Build) throws -> (any LanguageModel, Qwen35InlineMTPAssistant) {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let moe = build == .moe
        let text: [String: Any] = [
            "model_type": moe ? "qwen3_5_moe_text" : "qwen3_5_text", "hidden_size": 64,
            "num_hidden_layers": 4, "intermediate_size": 64,
            "num_attention_heads": 2, "num_key_value_heads": 1, "head_dim": 64,
            "linear_num_value_heads": 1, "linear_num_key_heads": 1,
            "linear_key_head_dim": 64, "linear_value_head_dim": 64,
            "linear_conv_kernel_dim": 4, "full_attention_interval": 2,
            "vocab_size": 64, "num_experts": moe ? 4 : 0, "num_experts_per_tok": moe ? 2 : 0,
            "moe_intermediate_size": 32, "shared_expert_intermediate_size": 32,
            "norm_topk_prob": true, "mtp_num_hidden_layers": 1,
        ]
        let outer: [String: Any] = [
            "model_type": build.modelType,
            "mtplx_mtp": ["included": true, "prefix": "mtp.", "block_size": 3],
            "mtplx_mtp_quantization": [String: Any](),
            "text_config": text,
        ]
        let json = try JSONSerialization.data(withJSONObject: outer)
        let configuration = try JSONDecoder().decode(Qwen35Configuration.self, from: json)
        MLXRandom.seed(moe ? 7053 : 7051)
        let model: Qwen35Model = moe ? Qwen35MoEModel(configuration) : Qwen35Model(configuration)
        model.update(
            parameters: ModuleParameters.unflattened(
                model.parameters().flattened().map { ($0.0, $0.1.asType(.bfloat16)) }))
        quantize(model: model, groupSize: 32, bits: 4) { _, module in
            module is Embedding || module is SwitchLinear
        }
        let weights = Dictionary(
            uniqueKeysWithValues: Qwen35MTPModule(configuration.textConfig).parameters().flattened()
                .map { ("mtp." + $0.0, $0.1.asType(.bfloat16)) })
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen35-card-donation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try json.write(to: directory.appendingPathComponent("config.json"))
        let shard = "model-00001-of-00001.safetensors"
        try save(arrays: weights, url: directory.appendingPathComponent(shard))
        try JSONSerialization.data(withJSONObject: [
            "weight_map": Dictionary(uniqueKeysWithValues: weights.keys.map { ($0, shard) })
        ]).write(to: directory.appendingPathComponent("model.safetensors.index.json"))
        eval(model)
        let assistant = try Qwen35InlineMTPAssistant.load(from: directory, target: model)
        return (model, assistant)
    }

    final class Fixture: @unchecked Sendable {
        let build: Build
        let model: any LanguageModel
        let assistant: Qwen35InlineMTPAssistant
        let root: URL
        let key = SymmetricKey(size: .bits256)
        let identity = CBv2CompleteCheckpointIdentity(
            modelAggregateHash: "qwen35-card-fixture", promptContractID: "qwen35-card-template",
            buildID: "fixture-build", numericsFingerprint: "paged-native")
        private var bridges: [EngineV2Bridge] = []
        private var stores: [SSDHybridCheckpointStore] = []

        init(_ build: Build) throws {
            self.build = build
            (model, assistant) = try Qwen35CardDefaultDonationTests.target(build)
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("qwen35-card-store-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        /// A store over `root`: a second one reopens the first one's files.
        func makeStore() throws -> SSDHybridCheckpointStore {
            let layout = CBv2CompleteCheckpointManifest.pagedLayout
            let modelRoot = root.appendingPathComponent(SSDHybridCheckpointStoreFactory.namespace(
                modelId: build.rawValue, identity: identity, backendLayout: layout))
            try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
            let fingerprint = Data(HMAC<SHA256>.authenticationCode(
                for: Data("darkbloom-cache-epoch-key-binding-v1".utf8), using: key)).hexString
            let epoch = try SSDCacheEpochStore(root: modelRoot, binding: .init(
                modelId: build.rawValue, modelAggregateHash: identity.modelAggregateHash,
                promptContractId: identity.promptContractID, blockHashVersion: CBv2BlockHasher.version,
                blockSize: PrefixCachePolicy.blockSize,
                layoutEpoch: SSDHybridCheckpointEnvelope.layoutEpoch(identity: identity, backendLayout: layout),
                keyFingerprint: fingerprint))
            let store = SSDHybridCheckpointStore(config: .init(
                modelId: build.rawValue, identity: identity, backendLayout: layout,
                root: modelRoot, dedicatedRoot: root, epochStore: epoch,
                maxReadBytes: SSDPrefixCachePolicy.maxStageBytes(environment: [:]),
                maxStageMillis: SSDPrefixCachePolicy.maxStageMillis(environment: [:]),
                minEffectiveTokens: SSDPrefixCachePolicy.minEffectiveTokens(environment: [:]),
                ttlSeconds: SSDPrefixCachePolicy.ttlSeconds(environment: [:]), strictFsync: false,
                nowSeconds: { Int64(Date().timeIntervalSince1970) }, diskBudgetBytes: { 1 << 30 },
                maintainWholeRoot: {}), kekKey: key, kvBudget: nil,
                maxWriteBytesPerDay: SSDPrefixCachePolicy.defaultMaxWriteBytesPerDay,
                usesEphemeralKey: true)
            stores.append(store)
            store.scanOnDisk()
            return store
        }

        /// The production assembly the slot factory builds for these IDs: native paged KV,
        /// native checkpoints, the provider's MTP policy shape for them (adaptive depth, typical
        /// acceptance) and the card's sampling defaults. The
        /// grant clears the bridge's 1 GiB load floor (`UnifiedMemoryCap.minimumLoadKVBytes`);
        /// paged storage allocates only what the requests use.
        func makeBridge(store: SSDHybridCheckpointStore?) throws -> (EngineV2Bridge, EngineV2) {
            var environment = ["DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE": String(Qwen35CardDefaultDonationTests.stripe)]
            if store == nil { environment["DARKBLOOM_PREFIX_CACHE"] = "0" }
            let tokenizer = IDTokenizer()
            let build = try EngineV2Factory.makeProductionBuild(
                model: model, modelID: self.build.rawValue, tokenizer: tokenizer,
                kvBytesCapacity: 4 << 30, maxConcurrentRequests: 1,
                completePrefixCache: store, mtpDrafter: assistant,
                mtpConfig: .init(
                    enabled: true, maxDraftTokens: CBv2MTPConfig.testedMaxDraftTokens,
                    verificationMode: .automatic, maxAutomaticRectangularTokens: 8,
                    acceptance: .typical(delta: CBv2MTPAcceptance.defaultTypicalDelta)),
                kvBackend: .paged, checkpointQuantization: .native, environment: environment)
            try #require(build.kvBackendKind == .paged && build.kvBackendFallbackReason == nil)
            let engine = try #require(build.engine as? EngineV2)
            try #require(engine.mtpMetricsSnapshot() != nil, "the inline assistant is active")
            if store != nil {
                try #require(engine.completeCheckpointCodec?.assistant != nil,
                             "the complete checkpoints carry the assistant's history")
            }
            let bridge = EngineV2Bridge(
                engine: build.engine, modelId: self.build.rawValue, tokenizer: TokenizerHandle(tokenizer),
                eosTokenIds: [], samplingDefaults: EngineV2SamplingDefaults.resolve(
                    modelId: self.build.rawValue, modelType: self.build.modelType, modelDirectory: nil),
                maxConcurrentRequests: 1, prefillDeadlineMode: .off,
                fixedRequestBytes: build.fixedRequestBytes, ssdHybridCheckpointStore: store,
                kvBackendKind: .paged)
            bridges.append(bridge)
            return (bridge, engine)
        }

        func close() async {
            for bridge in bridges { await bridge.shutdown() }
            bridges.removeAll()
            for store in stores { await store.closeAndWait() }
            stores.removeAll()
            try? FileManager.default.removeItem(at: root)
            MLX.Memory.clearCache()
        }
    }

    struct Served: Equatable {
        var text = ""
        var logprobBits: [UInt32] = []
        var finish: String?
        var hit = 0
    }

    /// A request that sends no sampling field: the provider's card defaults apply.
    static func request(_ build: Build, _ extra: Extra) -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: build.rawValue, messages: [ChatMessage(role: "user", content: "pre-tokenized")],
            max_tokens: maxTokens, stop: extra == .stop ? .single("<never-matches>") : nil,
            seed: 77, logprobs: extra == .logprobs ? true : nil,
            top_logprobs: extra == .logprobs ? 5 : nil)
    }

    static func serve(
        _ bridge: EngineV2Bridge, _ request: ChatCompletionRequest, id: String
    ) async throws -> Served {
        let signal = EngineV2RequestUsageSignal()
        let stream = await bridge.submitTokenized(
            promptTokens: prompt, request: request, requestId: id, cacheScope: "tenant-a",
            usageSignal: signal)
        var served = Served()
        var failure: String?
        for await event in stream {
            switch event {
            case .chunk(let text): served.text += text
            case .logprobs(let entries):
                for entry in entries {
                    served.logprobBits.append(entry.logprob.bitPattern)
                    served.logprobBits += entry.topLogprobs.map(\.logprob.bitPattern)
                }
            case .info(_, _, _, let reason): served.finish = reason
            case .error(let message): failure = message
            case .terminal(_, let message, _, _): failure = message
            }
        }
        try #require(failure == nil, "request \(id) failed: \(failure ?? "")")
        served.hit = signal.prefixCacheHitTokens ?? 0
        return served
    }

    static func drafted(_ engine: EngineV2) -> Int {
        engine.mtpMetricsSnapshot()?.draftedTokens ?? 0
    }

    static func idle(_ bridge: EngineV2Bridge) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while true {
            let capacity = await bridge.capacitySnapshot()
            if capacity.activeRequests == 0 && capacity.waitingRequests == 0
                && capacity.kvBytesInUse == 0 && capacity.kvBytesReserved == 0
            {
                return
            }
            try #require(ContinuousClock.now < deadline, "request accounting did not drain")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("a card-default request donates, and the next one restores it exactly",
          .timeLimit(.minutes(5)), arguments: Build.allCases, Extra.allCases)
    func cardDefaultRequestDonatesAndRestoresExactly(_ build: Build, _ extra: Extra) async throws {
        let fixture = try Fixture(build)
        do {
            let request = Self.request(build, extra)

            let (coldBridge, coldEngine) = try fixture.makeBridge(store: nil)
            let defaults = await coldBridge.samplingDefaults
            #expect(defaults == EngineV2SamplingDefaults.qwen35CardDefaults,
                    "the provider keeps the card's presence penalty")
            #expect(defaults.presencePenalty == 1.5)
            let cold = try await Self.serve(coldBridge, request, id: "cold")
            #expect(cold.finish == "length")
            #expect(cold.hit == 0)
            #expect(!cold.text.isEmpty)
            #expect(extra != .logprobs || !cold.logprobBits.isEmpty)
            #expect(Self.drafted(coldEngine) == 0, "the card request never drafts")
            try await Self.idle(coldBridge)
            await coldBridge.shutdown()

            let donorStore = try fixture.makeStore()
            let (donorBridge, donorEngine) = try fixture.makeBridge(store: donorStore)
            let donor = try await Self.serve(donorBridge, request, id: "donor")
            #expect(donor == cold, "capture does not change the answer")
            #expect(Self.drafted(donorEngine) == 0, "the donor never speculates")
            try await Self.idle(donorBridge)
            await donorStore.waitForWritesForTesting()
            let written = donorStore.stats().filesWritten
            #expect(written == 2, "the card request donates its chunk ends at 1,024 and 2,048")
            await donorBridge.shutdown()
            await donorStore.closeAndWait()

            let warmStore = try fixture.makeStore()
            try #require(warmStore.stats().entries == written, "the reopened store scans the donated files")
            let (warmBridge, _) = try fixture.makeBridge(store: warmStore)
            var warm = try await Self.serve(warmBridge, request, id: "warm")
            #expect(warm.hit == 2 * Self.stripe, "the next request restores the deepest chunk end")
            warm.hit = 0
            #expect(warm == cold, "a restored request answers exactly as its cold run")
            try await Self.idle(warmBridge)
            await warmBridge.shutdown()
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }
}
