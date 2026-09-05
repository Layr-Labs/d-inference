// Copyright © 2026 Eigen Labs.
//
// The runner boundary, provider side (Darkbloom runner contract §3, §5, §6.2
// rule 4, §9, §12c).
//
// Three properties, none of which needs weights:
//
//   1. the advertised set is exactly what `RunnerRegistry` claims — the
//      hand-kept family list is gone, so a family is advertised if and only
//      if a runner claims its `model_type`;
//   2. the POLICY a slot computed reaches the runner intact on
//      `EngineBuild`, and the runner's engine comes back inside the
//      `ProductionBuild` shape the bridge already reads;
//   3. speculation is decoder SELECTION on the runner: `mtp` only when the
//      runner reports it loaded, a refusal otherwise, and the Qwen 3.8
//      Flash-Next n-gram table crosses as a load-time resource under the
//      name its runner declares.

import Foundation
import MLX
import MLXLMCommon
import MLXNN
import MLXRunners
import Testing

@testable import ProviderCore

// MARK: - Scripted runner (no weights)

private final class ScriptedRunnerModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

/// A `Runner` that loads nothing, records the `EngineBuild` it is handed,
/// and returns an inert engine. It is the whole point of the contract's
/// caller/runner split that this is possible: the provider's policy is data
/// on `EngineBuild`, so it can be asserted without a model.
private final class ScriptedRunner: Runner, @unchecked Sendable {

    static let manifest = RunnerManifest(
        runnerID: "test/scripted",
        modelTypes: ["scripted_test"],
        engine: CBv2ModelCapabilities(
            supportsPrefixReuse: true,
            supportsPagedKV: false,
            supportsCompiledDecode: false,
            supportsPackedPrefill: false,
            supportsMTP: true,
            supportsCompactRecurrentMTPReplay: false),
        kvBackends: [.contiguous],
        decoders: [
            DecoderDeclaration(
                mode: DecoderID.serial.rawValue, drafter: .none, state: .stateless,
                depth: nil),
            DecoderDeclaration(
                mode: DecoderID.mtp.rawValue, drafter: .embeddedHead,
                state: .requestStateful, depth: 1 ... 3),
        ],
        regimes: [
            RegimeDeclaration(batch: .single, timing: .freeRun, perStreamTiming: false)
        ],
        multimodal: false,
        recurrentLayers: false,
        requiresKeepMask: false)

    let servingModel: any LanguageModel = ScriptedRunnerModel()
    let tokenizer: any MLXLMCommon.Tokenizer = StubBridgeTokenizer()
    let eosTokenIDs: Set<Int> = []
    let layerKinds: [CBv2LayerKind] = []
    let loadedDecoders: [DecoderID]
    let headProvenance: HeadProvenance? = nil
    let loadedModelType: String = "scripted_test"

    /// The engine every `makeEngine` returns, and the build it last saw.
    let engine = InertStubEngine(kvBytesCapacity: 0)
    private let lock = NSLock()
    private var _receivedBuild: EngineBuild?
    private let failure: Error?

    var receivedBuild: EngineBuild? { lock.withLock { _receivedBuild } }

    init(loadedDecoders: [DecoderID] = [.serial, .mtp], failure: Error? = nil) {
        self.loadedDecoders = loadedDecoders
        self.failure = failure
    }

    /// What the last `load` was handed. The registry resolves a TYPE, so the
    /// only place a load-path test can observe the caller's options is here.
    static let lastLoad = LoadRecord()

    final class LoadRecord: @unchecked Sendable {
        private let lock = NSLock()
        private var _directory: URL?
        private var _options: RunnerLoadOptions?
        var directory: URL? { lock.withLock { _directory } }
        var options: RunnerLoadOptions? { lock.withLock { _options } }
        func record(_ directory: URL, _ options: RunnerLoadOptions) {
            lock.withLock {
                _directory = directory
                _options = options
            }
        }
    }

    static func load(_ directory: URL, options: RunnerLoadOptions) -> ScriptedRunner {
        lastLoad.record(directory, options)
        return ScriptedRunner()
    }

    func makeEngine(_ build: EngineBuild) throws -> any CBv2Engine {
        lock.withLock { _receivedBuild = build }
        if let failure { throw failure }
        return engine
    }

    func makeStepper() throws -> any TeacherForcedStepper {
        throw RunnerError.invalidCheckpoint("scripted runner has no stepper")
    }
}

private func makePolicy(
    kind: EngineV2KVBackendKind = .contiguous,
    fallbackReason: String? = nil,
    capacity: Int = 4 * 1024 * 1024 * 1024,
    prefixCache: (any CBv2PrefixCache)? = nil,
    mtpConfig: CBv2MTPConfig = CBv2MTPConfig()
) -> EngineV2RunnerPolicy {
    EngineV2RunnerPolicy(
        kvBackendKind: kind,
        kvBackendFallbackReason: fallbackReason,
        kvBytesCapacity: capacity,
        schedulerConfig: EngineV2Factory.productionSchedulerConfig(
            maxConcurrentRequests: 6,
            model: nil,
            environment: ["DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE": "3072"]),
        loopConfig: CBv2EngineLoopConfig(useLegacyRequestTimeout: true),
        prefixCache: prefixCache,
        mtpConfig: mtpConfig,
        environment: ["DARKBLOOM_TEST_MARKER": "runner-boundary"])
}

// MARK: - 1. Advertise gate

@Suite("EngineV2 advertise gate is the runner registry")
struct EngineV2RunnerRegistryGateTests {

    @Test("the registry claims every first-party runner's model types")
    func registryClaimsEveryFamily() {
        for modelType in [
            "gemma4", "gemma4_text",  // Gemma 4 text runner
            "gpt_oss",  // GPT-OSS runner
            "qwen3_5", "qwen3_5_moe", "qwen3_5_text",  // Qwen 3.5 runner
            "qwen3_vl", "qwen3_vl_moe",  // Qwen3-VL runner
            "qwen4_exp", "qwen4_exp_text",  // Qwen 3.8 Flash-Next runner
        ] {
            #expect(
                RunnerRegistry.shared.contains(modelType: modelType),
                "type=\(modelType)")
        }
    }

    @Test("the four container-loaded families are advertised")
    func containerServableFamiliesAreAdvertised() {
        for modelType in [
            "gemma4", "gemma4_text", "gpt_oss", "qwen3_5", "qwen3_5_moe",
            "qwen3_vl", "qwen3_vl_moe",
        ] {
            #expect(
                EngineV2SupportedModels.isSupported(modelType: modelType),
                "type=\(modelType)")
        }
    }

    @Test("a claimed family the slot cannot build yet is withheld, not advertised")
    func claimedButUnservableIsWithheld() {
        // Qwen 3.8 Flash-Next is claimed by its runner and cannot be built
        // over an already-resident ModelContainer: its forward pass needs the
        // n-gram row source, which only `Runner.load` can be given. Withheld
        // until the slot lifecycle loads through the registry — a clean 404
        // rather than a load-then-503.
        for modelType in ["qwen4_exp", "qwen4_exp_text", "qwen3_5_text"] {
            #expect(RunnerRegistry.shared.contains(modelType: modelType))
            #expect(
                !EngineV2SupportedModels.isSupported(modelType: modelType),
                "type=\(modelType)")
        }
    }

    @Test("a family no runner claims stays unadvertised")
    func unclaimedFamiliesFailClosed() {
        for modelType in [
            "gemma3", "llama", "qwen3", "qwen3_moe", "gemma4_assistant",
            "qwen4", "qwen4_exp_assistant", "",
        ] {
            #expect(
                !EngineV2SupportedModels.isSupported(modelType: modelType),
                "type=\(modelType)")
        }
        #expect(!EngineV2SupportedModels.isSupported(modelType: nil))
    }

    @Test("the gate normalizes case and surrounding whitespace before the lookup")
    func gateNormalizesBeforeLookup() {
        #expect(EngineV2SupportedModels.isSupported(modelType: " QWEN3_5_MOE "))
        #expect(EngineV2SupportedModels.isSupported(modelType: "Gemma4_Text"))
        #expect(!EngineV2SupportedModels.isSupported(modelType: " GEMMA3 "))
    }

    @Test("nothing is advertised that no runner claims")
    func gateNeverExceedsTheRegistry() {
        for modelType in EngineV2ModelAdaptation.containerServableModelTypes {
            #expect(
                RunnerRegistry.shared.contains(modelType: modelType),
                "the provider would advertise \(modelType) with no runner behind it")
        }
    }
}

// MARK: - 2. Policy reaches the runner

@Suite("Runner engine build carries the slot's policy")
struct EngineV2RunnerBuildTests {

    @Test("the runner receives the backend, capacity, and scheduler config the slot computed")
    func policyCrossesOnEngineBuild() throws {
        let runner = ScriptedRunner()
        let policy = makePolicy(capacity: 7_654_321)
        let build = try EngineV2Factory.makeRunnerBuild(
            runner: runner, decoder: .serial, policy: policy)

        let received = try #require(runner.receivedBuild)
        #expect(received.kvBackend == .contiguous)
        #expect(received.kvBytesCapacity == 7_654_321)
        #expect(received.schedulerConfig.maxConcurrentRequests == 6)
        #expect(received.schedulerConfig.soloPrefillStripeTokens == 3072)
        #expect(
            received.schedulerConfig.maxConcurrentPartialPrefills
                == EngineV2Factory.defaultMaxConcurrentPartialPrefills)
        #expect(received.loopConfig.useLegacyRequestTimeout)
        #expect(received.prefixCache == nil)
        #expect(received.decoder == .serial)
        #expect(received.environment["DARKBLOOM_TEST_MARKER"] == "runner-boundary")
        // The result keeps the shape the bridge already reads.
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvBackendFallbackReason == nil)
        #expect(build.pagedPoolDType == nil)
        #expect(build.fixedRequestBytes == 0)
        #expect(build.engine === runner.engine)
    }

    @Test("a degraded paged selection is reported, not re-decided")
    func degradedSelectionPassesThrough() throws {
        let runner = ScriptedRunner()
        let build = try EngineV2Factory.makeRunnerBuild(
            runner: runner,
            decoder: .serial,
            policy: makePolicy(kind: .contiguous, fallbackReason: "kill_switch"))
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvBackendFallbackReason == "kill_switch")
        #expect(try #require(runner.receivedBuild).kvBackend == .contiguous)
    }

    @Test("a runner refusal lands on the existing refusal reasons")
    func runnerRefusalsClassify() {
        #expect(
            EngineV2RefusalReason.classify(
                RunnerError.kvBackendRefused(requested: "paged", declared: ["contiguous"]))
                == .pagedBackendUnavailable)
        #expect(
            EngineV2RefusalReason.classify(RunnerError.unexpectedModel("Other"))
                == .unsupportedModel)
        #expect(
            EngineV2RefusalReason.classify(
                RunnerRegistry.RegistryError.unknownModelType("llama"))
                == .unsupportedModel)
        #expect(
            EngineV2RefusalReason.classify(
                RunnerError.resourceMissing("qwen4exp.ngramRowSource: absent"))
                == .runnerResourceMissing)
        #expect(
            EngineV2RefusalReason.classify(
                RunnerError.decoderNotLoaded(requested: "mtp", loaded: ["serial"]))
                == .engineInitFailed)
    }

    @Test("a throwing runner surfaces its refusal rather than an engine")
    func refusalIsNotSwallowed() {
        let runner = ScriptedRunner(
            failure: RunnerError.kvBackendRefused(
                requested: "paged", declared: ["contiguous"]))
        #expect(throws: RunnerError.self) {
            _ = try EngineV2Factory.makeRunnerBuild(
                runner: runner, decoder: .serial, policy: makePolicy())
        }
    }
}

// MARK: - 3. Qwen 3.8 Flash-Next: decoder selection and the n-gram resource

@Suite("Qwen 3.8 Flash-Next runner wiring")
struct EngineV2Qwen38RunnerWiringTests {

    @Test("mtp is selected only when the runner reports the head loaded")
    func decoderSelectionFollowsLoadedDecoders() throws {
        let withHead = ScriptedRunner(loadedDecoders: [.serial, .mtp])
        #expect(
            try EngineV2Factory.runnerDecoder(
                runner: withHead, speculationRequested: true) == .mtp)
        #expect(
            try EngineV2Factory.runnerDecoder(
                runner: withHead, speculationRequested: false) == .serial)

        let serialOnly = ScriptedRunner(loadedDecoders: [.serial])
        #expect(
            try EngineV2Factory.runnerDecoder(
                runner: serialOnly, speculationRequested: false) == .serial)
        // A decoder the runner did not load is refused, never downgraded:
        // `mtp_active` must not claim a head that is not running.
        #expect(throws: RunnerError.self) {
            _ = try EngineV2Factory.runnerDecoder(
                runner: serialOnly, speculationRequested: true)
        }
    }

    @Test("the selected decoder and MTP config reach the engine build")
    func speculativeBuildCarriesTheDecoder() throws {
        let runner = ScriptedRunner(loadedDecoders: [.serial, .mtp])
        let decoder = try EngineV2Factory.runnerDecoder(
            runner: runner, speculationRequested: true)
        _ = try EngineV2Factory.makeRunnerBuild(
            runner: runner,
            decoder: decoder,
            policy: makePolicy(
                mtpConfig: CBv2MTPConfig(enabled: true, fixedDraftTokens: 3)))
        let received = try #require(runner.receivedBuild)
        #expect(received.decoder == .mtp)
        #expect(received.mtpConfig.enabled)
        #expect(received.mtpConfig.fixedDraftTokens == 3)
    }

    @Test("the n-gram row source crosses as a load-time resource, directory shape")
    func ngramResourceIsInjectedAsADirectory() throws {
        let modelDirectory = URL(fileURLWithPath: "/models/qwen4-exp-125b-a6b")
        let options = EngineV2Factory.runnerLoadOptions(
            modelDirectory: modelDirectory,
            kvBytesCapacity: 1 << 30,
            maxSequenceLength: 8192,
            environment: [:])
        let resource = try #require(
            options.resources[Qwen4ExpRunner.ngramRowSourceResource])
        let url = try #require(resource as? URL)
        #expect(url.path == modelDirectory.path)
        // DIRECTORY shape, not a file: the reader refuses a single file by
        // name, so the URL must say which it is without touching the disk.
        #expect(url.hasDirectoryPath)
        #expect(options.kvBytesCapacity == 1 << 30)
        #expect(options.maxSequenceLength == 8192)
        #expect(options.drafterDirectory == nil)
    }

    @Test("the registry resolves a checkpoint and the load options reach the runner")
    func registryResolutionCarriesTheResources() async throws {
        RunnerRegistry.shared.register(ScriptedRunner.self)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-boundary-\(UUID().uuidString.prefix(8))",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"model_type":"scripted_test"}"#.utf8)
            .write(to: directory.appendingPathComponent("config.json"))

        let runner = try await EngineV2Factory.loadRunner(
            modelDirectory: directory,
            options: EngineV2Factory.runnerLoadOptions(
                modelDirectory: directory,
                kvBytesCapacity: 123_456,
                maxSequenceLength: 4096,
                environment: [:]))
        #expect(runner is ScriptedRunner)
        let recorded = try #require(ScriptedRunner.lastLoad.options)
        #expect(ScriptedRunner.lastLoad.directory?.path == directory.path)
        #expect(recorded.kvBytesCapacity == 123_456)
        #expect(
            recorded.resources[Qwen4ExpRunner.ngramRowSourceResource] != nil,
            "the caller's resources cross the boundary untouched")
    }
}
