// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLLM
import MLXNN
import Testing

@testable import MLXLMCommon
@testable import ProviderCore

struct GlimmerDrafterTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1, 2] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "x" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] { [1, 2] }
}

private actor GlimmerNoCatalog: SpecDecCatalogLooking {
    private(set) var calls = 0
    func cachedModel(id: String) -> CatalogModel? { calls += 1; return nil }
    func model(id: String) async throws -> CatalogModel? { calls += 1; return nil }
}

/// The DFlash drafter's provider wiring over tiny synthetic models: exact
/// windows and the numerics profile, the funnel gate, the pinned loader, the
/// checkpoint classification and the production engine with the drafter on.
/// No checkpoint and no downloaded data.
@Suite("Muse Glimmer drafter wiring", .serialized)
struct MuseGlimmerDrafterTests {
    static let modelID = MuseGlimmerModelPolicy.localModelID
    static let taps = [1, 3]

    /// 32 query heads over 2 KV heads of 128, as published, on four layers.
    /// At width 128 every projection has a row-exact product (inputs above
    /// 64); at 64 the attention projections do not.
    static func tower(hidden: Int = 128) throws -> MuseGlimmerTextModel {
        let text: [String: Any] = [
            "hidden_size": hidden, "num_hidden_layers": 4, "num_attention_heads": 32,
            "num_key_value_heads": 2, "head_dim": 128, "intermediate_size": 256,
            "sliding_window": 64, "vocab_size": 96, "rope_parameters": ["rope_theta": 500000.0],
        ]
        let model = MuseGlimmerTextModel(try JSONDecoder().decode(
            MuseGlimmerTextModelConfiguration.self, from: JSONSerialization.data(withJSONObject: text)))
        model.mtpHiddenLayerIDs = taps
        return model
    }

    static func exactTower() throws -> MuseGlimmerTextModel {
        let model = try tower()
        try MuseGlimmerServingLoad.enableExactWindows(model)
        return model
    }

    static func otherModel() throws -> GPTOSSModel {
        let text: [String: Any] = [
            "model_type": "gpt_oss", "num_hidden_layers": 2, "num_local_experts": 4,
            "num_experts_per_tok": 2, "vocab_size": 128, "rms_norm_eps": 1e-5,
            "hidden_size": 64, "intermediate_size": 64, "head_dim": 64,
            "num_attention_heads": 4, "num_key_value_heads": 2, "sliding_window": 32,
        ]
        return GPTOSSModel(try JSONDecoder().decode(
            GPTOSSConfiguration.self, from: JSONSerialization.data(withJSONObject: text)))
    }

    /// A seeded float32 drafter for `tower()`, written where the store
    /// accepts it (`config.json` and `model.safetensors` only), with the pin
    /// of its own bytes. The production pin cannot load it, which is the point.
    static func artifact(in root: URL) throws -> (directory: URL, pin: MuseGlimmerDFlashArtifactPin) {
        let configuration = try MuseGlimmerDFlashConfiguration(
            hiddenSize: 128, intermediateSize: 256, hiddenLayers: 2, attentionHeads: 4, kvHeads: 2,
            headDimensions: 32, blockSize: 8, maskTokenID: 95, targetLayerIDs: taps, slidingWindow: 64,
            rmsNormEps: 1e-5, ropeTheta: 500_000)
        let model = try MuseGlimmerDFlashDraftModel(configuration, dtype: .float32)
        let values = model.parameters().flattened().sorted { $0.0 < $1.0 }.enumerated().map { index, entry in
            let key = MLXRandom.key(UInt64(17 + index))
            let shape = entry.1.shape
            let value = shape.count == 1
                ? MLXRandom.uniform(low: Float(0.5), high: Float(1.5), shape, key: key)
                : MLXRandom.normal(shape, key: key) * (1 / Float(shape[1]).squareRoot())
            return (entry.0, value.asType(.float32))
        }
        try model.update(parameters: .unflattened(values), verify: .all)
        eval(model)
        let directory = root.appendingPathComponent("drafter", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let written = try model.writeArtifact(to: directory, source: "provider unit test")
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(MuseGlimmerDFlashArtifactManifest.fileName))
        return (directory, written.pin)
    }

    static func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-glimmer-drafter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Exact windows and the numerics profile

    @Test("serving turns exact windows on, and the fingerprint carries that profile")
    func exactWindows() throws {
        let model = try Self.tower()
        let plainProfile = model.numericsProfile
        #expect(!model.verifiesWindowsExactly && plainProfile != MuseGlimmerModelPolicy.servedNumericsProfile)
        // A plain tower gets no store.
        #expect(EngineV2SlotFactory.completeCheckpointNumerics(model: model) == nil)
        try MuseGlimmerServingLoad.enableExactWindows(model)
        #expect(model.verifiesWindowsExactly)
        // The SDK's report is the policy's served profile, and the fingerprint
        // carries the report itself.
        #expect(model.numericsProfile == MuseGlimmerModelPolicy.servedNumericsProfile)
        #expect(model.numericsProfile != plainProfile)
        #expect(EngineV2SlotFactory.completeCheckpointNumerics(model: model)
            == ["museGlimmer.numericsProfile": model.numericsProfile])
        // Other models add nothing to their fingerprint.
        #expect(EngineV2SlotFactory.completeCheckpointNumerics(model: try Self.otherModel()) == [:])
    }

    @Test("a projection without a row-exact product fails the load and leaves the tower plain")
    func exactWindowsRefuse() throws {
        let model = try Self.tower(hidden: 64)
        let plainProfile = model.numericsProfile
        #expect(throws: MuseGlimmerRowExactError.self) {
            try MuseGlimmerServingLoad.enableExactWindows(model)
        }
        #expect(!model.verifiesWindowsExactly && model.numericsProfile == plainProfile)
        #expect(EngineV2SlotFactory.completeCheckpointNumerics(model: model) == nil)
    }

    @Test("the profile separates checkpoint identities and changes nothing else")
    func profileInIdentity() throws {
        func identity(_ numerics: [String: String]) -> CBv2CompleteCheckpointIdentity? {
            PrefixCachePolicy.completeCheckpointIdentity(
                modelAggregateHash: String(repeating: "a", count: 64),
                promptContractID: String(repeating: "b", count: 64),
                binaryHash: String(repeating: "c", count: 64),
                loadedMetallibHash: String(repeating: "d", count: 64), osVersion: "test",
                mtpConfig: CBv2MTPConfig(), assistantCodecID: nil, environment: [:],
                processEnvironment: [:], additionalNumerics: numerics)
        }
        let exactProfile = try Self.exactTower().numericsProfile
        let plainProfile = try Self.tower().numericsProfile
        let exact = try #require(identity(["museGlimmer.numericsProfile": exactProfile]))
        let plain = try #require(identity(["museGlimmer.numericsProfile": plainProfile]))
        let none = try #require(identity([:]))
        #expect(exact.numericsFingerprint != plain.numericsFingerprint)
        #expect(exact.numericsFingerprint != none.numericsFingerprint)
        #expect(exact.buildID == plain.buildID && exact.buildID == none.buildID)
        #expect(exact.modelAggregateHash == none.modelAggregateHash)
    }

    // MARK: - Funnel and loader

    @Test("the funnel offers a local drafter for the exact identity only")
    func funnelGate() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (directory, _) = try Self.artifact(in: root)
        let catalog = GlimmerNoCatalog()
        let funnel = SpecDecArtifactFunnel(
            resolver: SpecDecResolver(storeRoot: root.appendingPathComponent("store"),
                                     cdnBaseURL: "http://127.0.0.1:1"), catalog: catalog)
        let type = MuseGlimmerModelPolicy.modelType
        let cases: [(String, String, String?, [String: String], MTPFallbackReason?)] = [
            (MuseGlimmerModelPolicy.localModelID, type, directory.path, [:], nil),
            (MuseGlimmerModelPolicy.catalogModelID, type, directory.path, [:], nil),
            (MuseGlimmerModelPolicy.localModelID, type, "/missing-glimmer-drafter", [:], .localArtifactInvalid),
            (MuseGlimmerModelPolicy.localModelID, type, nil, [:], .artifactNotCached),
            (MuseGlimmerModelPolicy.localModelID, type, directory.path, ["DARKBLOOM_CBV2_MTP": "0"],
             .killSwitchDisabled),
            // The type under another id, and another type under the id.
            ("someone/Muse-Glimmer-30B-NVFP4", type, directory.path, [:], .targetUnsupported),
            (MuseGlimmerModelPolicy.localModelID, "llama", directory.path, [:], .targetUnsupported),
        ]
        for (id, modelType, path, environment, reason) in cases {
            let result = await funnel.prepare(.init(modelId: id, modelType: modelType, enabled: true,
                localPath: path, allowDownload: false, environment: environment))
            #expect(result.status.reason == reason, "\(id) \(modelType) \(path ?? "nil")")
            #expect((result.artifact != nil) == (reason == nil))
            if reason == nil { #expect(result.artifact?.source == .local) }
        }
        await funnel.shutdown()
    }

    @Test("the production loader takes only the pinned drafter; its pin binds it to the tower")
    func loader() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (directory, pin) = try Self.artifact(in: root)
        let artifact = try #require(SpecDecStore.inspectLocalArtifact(path: directory.path))
        let target = try Self.exactTower()

        // The production pin is the published quantized drafter: other bytes fail closed.
        do {
            _ = try await ProductionProviderMTPAssistantLoader().loadAndBind(artifact: artifact, target: target)
            Issue.record("a drafter that is not the pinned artifact loaded")
        } catch let error as ProviderMTPAssistantLoadError {
            #expect(error.reason == .assistantLoadFailed)
        }

        // The pin of these bytes binds them, with exact verification on the exact tower.
        let handle = try MuseGlimmerDrafterBinding.bind(
            directory: directory, target: target, pin: pin, environment: [:])
        let drafter = try #require(handle.drafter as? MuseGlimmerDFlashDrafter)
        #expect(drafter.settings.verification == .rectangularExact)
        #expect(drafter.settings.commitsAcceptedPrefixPerRow)
        // Up to four decoding requests per round by default (wide); `1` keeps one,
        // the binding before paired rounds, and `2` lets two share a round.
        #expect(drafter.settings.maximumSpeculativeRows == 4)
        let rowsKey = MTPAutomaticVerificationPolicy.museGlimmerSpeculativeRowsEnvironmentKey
        let one = try #require(try MuseGlimmerDrafterBinding.bind(
            directory: directory, target: target, pin: pin, environment: [rowsKey: "1"]).drafter
            as? MuseGlimmerDFlashDrafter)
        #expect(one.settings.maximumSpeculativeRows == 1 && one.settings.verification == .rectangularExact)
        let two = try #require(try MuseGlimmerDrafterBinding.bind(
            directory: directory, target: target, pin: pin, environment: [rowsKey: "2"]).drafter
            as? MuseGlimmerDFlashDrafter)
        #expect(two.settings.maximumSpeculativeRows == 2 && two.settings.verification == .rectangularExact)
        // Sampled rows propose the argmax by default; `1` couples them to their verify noise.
        #expect(!drafter.settings.couplesSampledProposals && !drafter.couplesSampledProposals)
        let coupledKey = MTPAutomaticVerificationPolicy.museGlimmerCoupledProposalsEnvironmentKey
        let coupled = try #require(try MuseGlimmerDrafterBinding.bind(
            directory: directory, target: target, pin: pin, environment: [coupledKey: "1"]).drafter
            as? MuseGlimmerDFlashDrafter)
        #expect(coupled.settings.couplesSampledProposals && coupled.couplesSampledProposals)
        #expect(coupled.settings.maximumSpeculativeRows == drafter.settings.maximumSpeculativeRows)
        // A step's requests share the drafter's passes by default; `0` takes one pass each.
        #expect(drafter.settings.batchesRequests && drafter.batchesRequests)
        let batchedKey = MTPAutomaticVerificationPolicy.museGlimmerBatchedRequestsEnvironmentKey
        let batched = try #require(try MuseGlimmerDrafterBinding.bind(
            directory: directory, target: target, pin: pin, environment: [batchedKey: "1"]).drafter
            as? MuseGlimmerDFlashDrafter)
        #expect(batched.settings.batchesRequests && batched.batchesRequests)
        #expect(!batched.settings.couplesSampledProposals)
        #expect(batched.settings.maximumSpeculativeRows == drafter.settings.maximumSpeculativeRows)
        let perRequest = try #require(try MuseGlimmerDrafterBinding.bind(
            directory: directory, target: target, pin: pin, environment: [batchedKey: "0"]).drafter
            as? MuseGlimmerDFlashDrafter)
        #expect(!perRequest.settings.batchesRequests && !perRequest.batchesRequests)
        #expect(perRequest.settings.maximumSpeculativeRows == drafter.settings.maximumSpeculativeRows)
        let wide = try #require(try MuseGlimmerDrafterBinding.bind(
            directory: directory, target: target, pin: pin, environment: [rowsKey: "wide", batchedKey: "1"]).drafter
            as? MuseGlimmerDFlashDrafter)
        #expect(wide.settings.maximumSpeculativeRows == 4 && wide.settings.batchesRequests)
        #expect(drafter.batchesVerifyColumnsAsDecodeRows)
        #expect(drafter.requiresExactAcceptance)
        #expect(drafter.maximumDraftTokens == 7)
        #expect(drafter.requestStateIsAdvisory)
        #expect(drafter.mtpTargetIdentity == ObjectIdentifier(target))

        // One wrong digest refuses.
        var wrong = pin
        wrong.weightsSHA256 = String(repeating: "0", count: 64)
        do {
            _ = try MuseGlimmerDrafterBinding.bind(directory: directory, target: target, pin: wrong)
            Issue.record("a drafter loaded under a pin its bytes do not match")
        } catch let error as ProviderMTPAssistantLoadError {
            #expect(error.reason == .assistantLoadFailed)
        }

        // A tower without exact windows verifies serially.
        let serial = try #require(try MuseGlimmerDrafterBinding.bind(
            directory: directory, target: try Self.tower(), pin: pin).drafter as? MuseGlimmerDFlashDrafter)
        #expect(serial.settings.verification == .serialTarget && !serial.settings.commitsAcceptedPrefixPerRow)
        #expect(!serial.batchesVerifyColumnsAsDecodeRows)
        #expect(serial.settings.maximumSpeculativeRows == 1)

        // A drafter of another width does not bind.
        do {
            _ = try MuseGlimmerDrafterBinding.bind(directory: directory, target: try Self.tower(hidden: 64), pin: pin)
            Issue.record("a drafter bound to a tower of another width")
        } catch let error as ProviderMTPAssistantLoadError {
            #expect(error.reason == .assistantTargetIncompatible)
        }

        // Another model never reaches the Glimmer arm.
        do {
            _ = try await ProductionProviderMTPAssistantLoader().loadAndBind(
                artifact: artifact, target: try Self.otherModel())
            Issue.record("a Glimmer drafter reached another model")
        } catch let error as ProviderMTPAssistantLoadError {
            #expect(error.reason == .assistantTargetIncompatible)
        }
    }

    // MARK: - Checkpoints

    @Test("an advisory drafter keeps historical checkpoints; typical acceptance keeps the refusal")
    func checkpointClassification() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (directory, pin) = try Self.artifact(in: root)
        let target = try Self.exactTower()
        let drafter = try #require(
            try MuseGlimmerDrafterBinding.bind(directory: directory, target: target, pin: pin).drafter)
        typealias Assistant = EngineV2SlotFactory.CompleteCheckpointAssistant
        #expect(Assistant(drafter: drafter) == .advisory)
        #expect(Assistant(drafter: drafter, acceptance: .exact) == .advisory)
        #expect(Assistant(drafter: drafter, acceptance: .typical(delta: CBv2MTPAcceptance.defaultTypicalDelta))
            == .unsupportedPersistent)
        #expect(Assistant(drafter: nil) == .none)
        #expect(!Assistant.advisory.keepsNativeStorage(pagedRecurrent: false))
        #expect(!Assistant.advisory.keepsNativeStorage(pagedRecurrent: true))

        let kinds = target.cbv2LayerKinds
        let types = target.kvStorageDTypes
        let pool = PagedKVPoolConfig(capacityBytes: 64 << 20, segmentSizeBytes: 1 << 20, layerDTypes: types)
        func storage(_ assistant: Assistant, quantization: PagedKVQuantizationConfig? = nil)
            -> CompleteCheckpointStorageIdentity?
        {
            EngineV2SlotFactory.completeCheckpointStorage(kind: .paged, layerKinds: kinds,
                supportsRecurrent: false, supportsHistoricalAttention: true, modelDTypes: types,
                nativeDTypes: types, pagedConfig: pool, assistant: assistant,
                checkpointQuantization: quantization)
        }
        let advisory = try #require(storage(.advisory))
        let none = try #require(storage(.none))
        // The same storage as without a drafter, native rows included.
        #expect(advisory.backendLayout == CBv2CompleteCheckpointManifest.historicalAttentionLayout)
        #expect(advisory.fingerprintFields == none.fingerprintFields)
        #expect(storage(.unsupportedPersistent) == nil)
    }

    // MARK: - Engine

    private func engine(
        _ target: MuseGlimmerTextModel, drafter: (any CBv2MTPDrafter)?, config: CBv2MTPConfig,
        requests: Int = 1
    ) throws -> EngineV2 {
        let engine = try EngineV2Factory.makeProductionEngine(
            model: target, modelID: Self.modelID, tokenizer: GlimmerDrafterTokenizer(),
            kvBytesCapacity: 64 << 20, maxConcurrentRequests: requests, mtpDrafter: drafter, mtpConfig: config,
            kvBackend: .paged, maxContextLength: 2048,
            environment: [KVBackendGuardStore.pathEnvKey: "/dev/null"])
        return try #require(engine as? EngineV2)
    }

    private func tokens(_ engine: EngineV2, _ request: CBv2Request) async throws -> [Int] {
        var tokens: [Int] = []
        var finished = false
        for await event in try engine.submit(request) {
            switch event {
            case .delta(_, let emitted, _): tokens += emitted
            case .finished: finished = true
            default: break
            }
        }
        #expect(finished)
        return tokens
    }

    /// The production backend and scheduler for `target`, driven through the
    /// generic adapter that served the model before the switch.
    private func genericEngine(_ target: MuseGlimmerTextModel) throws -> EngineV2 {
        let prepared = try EngineV2Factory.prepareProductionBackend(
            model: target, modelID: Self.modelID, kvBytesCapacity: 64 << 20, maxConcurrentRequests: 1,
            kvBackend: .paged, maxContextLength: 2048,
            environment: [KVBackendGuardStore.pathEnvKey: "/dev/null"])
        let (backend, caches) = try prepared.consume(model: target, maxConcurrentRequests: 1)
        let admission = try (backend as? PagedKVBackend)?.pool.admissionStorageConfig(AdmissionV2.Config())
            ?? AdmissionV2.Config()
        return EngineV2(
            model: CBv2SteppableLanguageModelAdapter(target), layerKinds: prepared.layerKinds,
            backend: backend, cacheProvider: CBv2LayerCacheBank(caches: caches),
            detokenizerFactory: CBv2TextDetokenizerFactory(tokenizer: GlimmerDrafterTokenizer()),
            schedulerConfig: prepared.schedulerConfig, admissionConfig: admission)
    }

    @Test("the production adapter is Muse Glimmer's own; without a drafter it serves the same tokens")
    func adapter() async throws {
        let target = try Self.exactTower()
        #expect(EngineV2Factory.steppableModel(target) is MuseGlimmerCBv2Adapter)
        #expect(EngineV2Factory.steppableModel(try Self.otherModel()) is CBv2SteppableLanguageModelAdapter)
        let prompt = (0 ..< 40).map { ($0 * 5 + 1) % 90 }
        for sampling in [CBv2SamplingParams(temperature: 0),
                         CBv2SamplingParams(temperature: 1, topP: 0.95, topK: 64, seed: 7)] {
            let request = CBv2Request(id: .init(1), promptTokens: prompt, sampling: sampling, maxTokens: 24)
            let generic = try genericEngine(target)
            let before = try await tokens(generic, request)
            await generic.shutdown()
            let own = try engine(target, drafter: nil, config: CBv2MTPConfig())
            let after = try await tokens(own, request)
            await own.shutdown()
            #expect(before.count == 24 && after == before, "temperature \(sampling.temperature)")
        }
    }

    @Test("with the drafter each round verifies in one exact forward, and the tokens are the target's")
    func engineWithDrafter() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (directory, pin) = try Self.artifact(in: root)
        let target = try Self.exactTower()
        let drafter = try #require(
            try MuseGlimmerDrafterBinding.bind(directory: directory, target: target, pin: pin).drafter)
        // The slot factory's resolution for this drafter.
        let depth = MTPAutomaticVerificationPolicy.draftDepthPolicy(
            usesRequestStatefulDrafter: drafter is any CBv2MTPRequestStatefulDrafter, modelID: Self.modelID)
        let verification = providerMTPVerificationPolicy(for: drafter, automaticRectangularTokens: 8)
        let config = CBv2MTPConfig(
            enabled: true, maxDraftTokens: depth.maximum, fixedDraftTokens: depth.fixed,
            verificationMode: verification.mode,
            maxAutomaticRectangularTokens: verification.automaticRectangularTokens,
            acceptance: MTPAcceptancePolicy.resolve(global: nil, byModel: [:], modelID: Self.modelID).acceptance)
        #expect(config.verificationMode == .rectangularExact)
        #expect(config.fixedDraftTokens == 7 && config.maxDraftTokens == 7)

        let prompt = (0 ..< 40).map { ($0 * 7 + 3) % 90 }
        let samplings = [CBv2SamplingParams(temperature: 0),
                         CBv2SamplingParams(temperature: 1, topP: 0.95, topK: 64, seed: 99)]
        for sampling in samplings {
            // One request id for both: the sampler keys its noise by it.
            let request = CBv2Request(id: .init(1), promptTokens: prompt, sampling: sampling, maxTokens: 24)
            let plain = try engine(target, drafter: nil, config: CBv2MTPConfig())
            let off = try await tokens(plain, request)
            await plain.shutdown()
            let speculative = try engine(target, drafter: drafter, config: config)
            #expect(speculative.mtpInactiveReason == nil)
            if case .bounded(let admission)? = speculative.resolvedMTPAdmission {
                #expect(admission.fixedBytesPerRequest > 0 && admission.residentBytesPerToken == 0)
            } else {
                Issue.record("the drafter has no bounded admission: \(String(describing: speculative.resolvedMTPAdmission))")
            }
            let on = try await tokens(speculative, request)
            let metrics = try #require(speculative.mtpMetricsSnapshot())
            await speculative.shutdown()
            #expect(off.count == 24)
            #expect(on == off, "temperature \(sampling.temperature)")
            #expect(metrics.verificationMode == .rectangularExact)
            #expect(metrics.rounds > 0 && metrics.rectangularVerificationRounds > 0)
            #expect(metrics.serialVerificationRounds == 0)
        }
    }

    /// Every request's tokens, the requests submitted together and read concurrently.
    private func concurrentTokens(_ engine: EngineV2, _ requests: [CBv2Request]) async throws -> [[Int]] {
        let streams = try requests.map { try engine.submit($0) }
        var results: [(Int, [Int], Bool)] = []
        await withTaskGroup(of: (Int, [Int], Bool).self) { group in
            for (index, stream) in streams.enumerated() {
                group.addTask {
                    var tokens: [Int] = []
                    var finished = false
                    for await event in stream {
                        switch event {
                        case .delta(_, let emitted, _): tokens += emitted
                        case .finished: finished = true
                        default: break
                        }
                    }
                    return (index, tokens, finished)
                }
            }
            for await result in group { results.append(result) }
        }
        #expect(results.allSatisfy { $0.2 })
        return results.sorted { $0.0 < $1.0 }.map(\.1)
    }

    @Test("two decoding requests share exact rounds at the paired depth; their tokens are the target's")
    func pairedRounds() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (directory, pin) = try Self.artifact(in: root)
        let target = try Self.exactTower()
        let rowsKey = MTPAutomaticVerificationPolicy.museGlimmerSpeculativeRowsEnvironmentKey
        // The slot factory's resolution: paired (`2`), one row (`1`) and the wide default.
        func resolved(_ environment: [String: String]) throws -> (any CBv2MTPDrafter, CBv2MTPConfig) {
            let drafter = try #require(try MuseGlimmerDrafterBinding.bind(
                directory: directory, target: target, pin: pin, environment: environment).drafter)
            let depth = MTPAutomaticVerificationPolicy.draftDepthPolicy(
                usesRequestStatefulDrafter: true, modelID: Self.modelID, environment: environment)
            var config = CBv2MTPConfig(
                enabled: true, maxDraftTokens: depth.maximum, fixedDraftTokens: depth.fixed,
                verificationMode: .rectangularExact)
            #expect(MTPAutomaticVerificationPolicy.applyMuseGlimmerSpeculativeRows(
                to: &config, modelID: Self.modelID, environment: environment) == nil)
            return (drafter, config)
        }
        let prompts = [(0 ..< 40).map { ($0 * 7 + 3) % 90 }, (0 ..< 33).map { ($0 * 11 + 5) % 90 }]
        let samplings = [CBv2SamplingParams(temperature: 0),
                         CBv2SamplingParams(temperature: 1, topP: 0.95, topK: 64, seed: 99)]
        for sampling in samplings {
            let requests = prompts.enumerated().map { index, prompt in
                CBv2Request(id: .init(UInt64(10 + index)), promptTokens: prompt, sampling: sampling, maxTokens: 32)
            }
            let plain = try engine(target, drafter: nil, config: CBv2MTPConfig(), requests: 2)
            let off = try await concurrentTokens(plain, requests)
            await plain.shutdown()
            #expect(off.map(\.count) == [32, 32])
            for (environment, pairs) in [([rowsKey: "2"], true), ([rowsKey: "1"], false), ([:], true)]
                as [([String: String], Bool)] {
                let (drafter, config) = try resolved(environment)
                let speculative = try engine(target, drafter: drafter, config: config, requests: 2)
                #expect(speculative.mtpInactiveReason == nil)
                let on = try await concurrentTokens(speculative, requests)
                let metrics = try #require(speculative.mtpMetricsSnapshot())
                await speculative.shutdown()
                #expect(on == off, "temperature \(sampling.temperature) \(environment)")
                #expect(metrics.serialVerificationRounds == 0)
                // Paired, and wide (the default): both rows pass the batch gate and their rounds draft three each.
                // One row: two decoding rows exceed the one-row gate and decode plainly.
                let gated = metrics.skippedRows["batch_gate"] ?? 0
                #expect(pairs ? gated == 0 && (metrics.depthSelections[3] ?? 0) > 0 : gated > 0,
                        "\(metrics.skippedRows) \(metrics.depthSelections)")
                #expect(!pairs || metrics.rounds > 0)
            }
        }
    }

    @Test("coupled proposals keep a sampled request's tokens the target's, alone and paired; argmax is the default")
    func coupledProposals() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (directory, pin) = try Self.artifact(in: root)
        let target = try Self.exactTower()
        let coupledKey = MTPAutomaticVerificationPolicy.museGlimmerCoupledProposalsEnvironmentKey
        let rowsKey = MTPAutomaticVerificationPolicy.museGlimmerSpeculativeRowsEnvironmentKey
        let prompts = [(0 ..< 40).map { ($0 * 7 + 3) % 90 }, (0 ..< 33).map { ($0 * 11 + 5) % 90 }]
        // Seeded, so two engines share each request's noise (an unseeded row is keyed by
        // its engine's own sampler; the SDK's coupled-proposal tests cover that case).
        let sampling = CBv2SamplingParams(temperature: 0.5, topP: 0.95, topK: 64, seed: 99)
        for count in [1, 2] {
            let requests = prompts.prefix(count).enumerated().map { index, prompt in
                CBv2Request(id: .init(UInt64(20 + index)), promptTokens: prompt, sampling: sampling, maxTokens: 32)
            }
            let plain = try engine(target, drafter: nil, config: CBv2MTPConfig(), requests: 2)
            let off = try await concurrentTokens(plain, requests)
            await plain.shutdown()
            #expect(off.allSatisfy { $0.count == 32 })
            // Paired rounds (`2`), so two requests share each round.
            for environment in [[coupledKey: "1", rowsKey: "2"], [rowsKey: "2"]] as [[String: String]] {
                let drafter = try #require(try MuseGlimmerDrafterBinding.bind(
                    directory: directory, target: target, pin: pin, environment: environment).drafter
                    as? MuseGlimmerDFlashDrafter)
                #expect(drafter.couplesSampledProposals == (environment[coupledKey] == "1"))
                let depth = MTPAutomaticVerificationPolicy.draftDepthPolicy(
                    usesRequestStatefulDrafter: true, modelID: Self.modelID, environment: environment)
                var config = CBv2MTPConfig(
                    enabled: true, maxDraftTokens: depth.maximum, fixedDraftTokens: depth.fixed,
                    verificationMode: .rectangularExact)
                _ = MTPAutomaticVerificationPolicy.applyMuseGlimmerSpeculativeRows(
                    to: &config, modelID: Self.modelID, environment: environment)
                let speculative = try engine(target, drafter: drafter, config: config, requests: 2)
                let on = try await concurrentTokens(speculative, requests)
                let metrics = try #require(speculative.mtpMetricsSnapshot())
                await speculative.shutdown()
                #expect(on == off, "rows \(count) \(environment)")
                #expect(metrics.rounds > 0 && metrics.serialVerificationRounds == 0)
            }
        }
    }

    @Test("batched requests keep every request's tokens the target's, paired, over the gate and wide; batched is the default")
    func batchedRequests() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (directory, pin) = try Self.artifact(in: root)
        let target = try Self.exactTower()
        let batchedKey = MTPAutomaticVerificationPolicy.museGlimmerBatchedRequestsEnvironmentKey
        let rowsKey = MTPAutomaticVerificationPolicy.museGlimmerSpeculativeRowsEnvironmentKey
        let prompts = [
            (0 ..< 40).map { ($0 * 7 + 3) % 90 }, (0 ..< 33).map { ($0 * 11 + 5) % 90 },
            (0 ..< 47).map { ($0 * 5 + 1) % 90 }, (0 ..< 29).map { ($0 * 13 + 2) % 90 },
        ]
        let samplings = [
            CBv2SamplingParams(temperature: 0.5, topP: 0.95, topK: 64, seed: 99), CBv2SamplingParams(temperature: 0),
        ]
        // Paired rounds (`2`): two requests speculate together, and three exceed the
        // gate and decode plainly (observed in one call when batched). `wide`: four
        // requests fill a round. Each width runs batched (the default, and `1`) and one pass per request (`0`);
        // four requests also run with nothing set (wide and batched by default).
        for (count, rows) in [(2, "2"), (3, "2"), (4, "wide")] {
            let requests = prompts.prefix(count).enumerated().map { index, prompt in
                CBv2Request(
                    id: .init(UInt64(40 + index)), promptTokens: prompt, sampling: samplings[index % 2],
                    maxTokens: 32)
            }
            let plain = try engine(target, drafter: nil, config: CBv2MTPConfig(), requests: count)
            let off = try await concurrentTokens(plain, requests)
            await plain.shutdown()
            #expect(off.allSatisfy { $0.count == 32 })
            let environments: [[String: String]] = [[rowsKey: rows, batchedKey: "1"], [rowsKey: rows],
                                                    [rowsKey: rows, batchedKey: "0"]] + (count == 4 ? [[:]] : [])
            for environment in environments {
                let drafter = try #require(try MuseGlimmerDrafterBinding.bind(
                    directory: directory, target: target, pin: pin, environment: environment).drafter
                    as? MuseGlimmerDFlashDrafter)
                #expect(drafter.batchesRequests == (environment[batchedKey] != "0"))
                let depth = MTPAutomaticVerificationPolicy.draftDepthPolicy(
                    usesRequestStatefulDrafter: true, modelID: Self.modelID, environment: environment)
                var config = CBv2MTPConfig(
                    enabled: true, maxDraftTokens: depth.maximum, fixedDraftTokens: depth.fixed,
                    verificationMode: .rectangularExact)
                _ = MTPAutomaticVerificationPolicy.applyMuseGlimmerSpeculativeRows(
                    to: &config, modelID: Self.modelID, environment: environment)
                let speculative = try engine(target, drafter: drafter, config: config, requests: count)
                let on = try await concurrentTokens(speculative, requests)
                let metrics = try #require(speculative.mtpMetricsSnapshot())
                await speculative.shutdown()
                #expect(on == off, "rows \(count) \(environment)")
                #expect(metrics.serialVerificationRounds == 0, "rows \(count) \(environment)")
                if count != 3 { #expect(metrics.rounds > 0, "rows \(count) \(environment)") }
            }
        }
    }

    @Test("under typical acceptance the drafter stays inactive and the slot serves the target alone")
    func typicalAcceptance() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (directory, pin) = try Self.artifact(in: root)
        let target = try Self.exactTower()
        let drafter = try #require(
            try MuseGlimmerDrafterBinding.bind(directory: directory, target: target, pin: pin).drafter)
        let config = CBv2MTPConfig(
            enabled: true, maxDraftTokens: 7, fixedDraftTokens: 7, verificationMode: .rectangularExact,
            acceptance: .typical(delta: CBv2MTPAcceptance.defaultTypicalDelta))
        let prompt = (0 ..< 40).map { ($0 * 7 + 3) % 90 }
        let request = CBv2Request(
            id: .init(1), promptTokens: prompt, sampling: CBv2SamplingParams(temperature: 0), maxTokens: 16)
        let plain = try engine(target, drafter: nil, config: CBv2MTPConfig())
        let off = try await tokens(plain, request)
        await plain.shutdown()
        let typical = try engine(target, drafter: drafter, config: config)
        #expect(typical.mtpInactiveReason == "drafter requires exact acceptance")
        let on = try await tokens(typical, request)
        let rounds = typical.mtpMetricsSnapshot()?.rounds ?? 0
        await typical.shutdown()
        #expect(off.count == 16 && on == off)
        #expect(rounds == 0)
    }
}
