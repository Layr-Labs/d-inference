// Copyright © 2026 Eigen Labs.
//
// Shared minimal CBv2 stubs for suites that need a ModelSlot but don't
// exercise generation (persistence, preload, idle-timeout, capacity guard
// tests). v0.7.5 slots REQUIRE a v2 bridge — these keep such suites
// weight-free.

import Foundation
import MLXLMCommon
import MLXNN
import MLXRunners

@testable import ProviderCore

/// Inert engine: accepts nothing, reports a fixed KV capacity, tracks
/// `updateKVBytesCapacity` calls so re-slice tests can assert grant flow.
final class InertStubEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var _kvBytesCapacity: Int
    private var _capacityUpdates: [Int] = []
    private var _shutdownCalls = 0
    /// Called synchronously INSIDE each `updateKVBytesCapacity`, i.e. at the
    /// exact instant the grant mutation lands — unwind-ordering tests use it
    /// to observe whether the failed newcomer's weights are still resident
    /// when a survivor's grant is restored.
    private let onUpdate: @Sendable (Int) -> Void

    init(kvBytesCapacity: Int = 0, onUpdate: @escaping @Sendable (Int) -> Void = { _ in }) {
        self._kvBytesCapacity = kvBytesCapacity
        self.onUpdate = onUpdate
    }

    var capacityUpdates: [Int] { lock.withLock { _capacityUpdates } }
    var shutdownCalls: Int { lock.withLock { _shutdownCalls } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        continuation.finish()
        return stream
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        lock.withLock {
            CBv2CapacitySnapshot(
                activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: _kvBytesCapacity, activeTokens: 0)
        }
    }
    func updateKVBytesCapacity(_ bytes: Int) {
        lock.withLock {
            _kvBytesCapacity = max(0, bytes)
            _capacityUpdates.append(max(0, bytes))
        }
        onUpdate(max(0, bytes))
    }
    func shutdown() async {
        lock.withLock { _shutdownCalls += 1 }
    }
}

/// Minimal tokenizer for stub bridges (never drives generation).
struct StubBridgeTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [] }
}

/// A slot-shaped stub bridge over an inert engine — enough for install/
/// unload/persistence/capacity-guard suites.
func makeInertStubBridge(
    modelId: String, kvBytesCapacity: Int = 0
) -> (bridge: EngineV2Bridge, engine: InertStubEngine) {
    let engine = InertStubEngine(kvBytesCapacity: kvBytesCapacity)
    let bridge = EngineV2Bridge(
        engine: engine,
        modelId: modelId,
        tokenizer: TokenizerHandle(StubBridgeTokenizer()),
        eosTokenIds: []
    )
    return (bridge, engine)
}

// MARK: - Runner-boundary stubs

/// A checkpoint directory holding only `config.json`.
///
/// Enough for the registry to resolve a family and for `Runner.adopt` to read
/// the checkpoint facts it needs — `adopt` reads no tensors, so a test that
/// built a tiny module in memory can hand it a directory like this and take
/// the real construction path.
func makeCheckpointDirectory(
    modelType: String, extra: [String: Any] = [:]
) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "runner-checkpoint-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    var config: [String: Any] = ["model_type": modelType]
    config.merge(extra) { _, new in new }
    try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        .write(to: directory.appendingPathComponent("config.json"))
    return directory
}

/// A `Runner` that adopts anything, holds whatever layer kinds and
/// capabilities the test states, records the `EngineBuild` it is handed, and
/// returns an inert engine.
///
/// The KV-backend gate is pure policy now — it decides over a runner's
/// declared layer kinds and capabilities and never touches a module — so the
/// gate suites drive it through this instead of building a tiny real model.
final class StubRunner: Runner, @unchecked Sendable {

    static let manifest = RunnerManifest(
        runnerID: "test/stub",
        modelTypes: ["stub_test"],
        engine: CBv2ModelCapabilities(),
        kvBackends: [.contiguous, .paged],
        decoders: [
            DecoderDeclaration(
                mode: DecoderID.serial.rawValue, drafter: .none, state: .stateless,
                depth: nil)
        ],
        regimes: [
            RegimeDeclaration(batch: .single, timing: .freeRun, perStreamTiming: false)
        ],
        multimodal: false,
        recurrentLayers: false,
        requiresKeepMask: false)

    let servingModel: any LanguageModel = StubRunnerModel()
    let tokenizer: any MLXLMCommon.Tokenizer = StubBridgeTokenizer()
    let eosTokenIDs: Set<Int> = []
    let layerKinds: [CBv2LayerKind]
    let loadedDecoders: [DecoderID] = [.serial]
    let headProvenance: HeadProvenance? = nil
    let loadedModelType: String
    let engine = InertStubEngine(kvBytesCapacity: 0)

    private let capabilities: CBv2ModelCapabilities
    private let lock = NSLock()
    private var _receivedBuild: EngineBuild?
    var receivedBuild: EngineBuild? { lock.withLock { _receivedBuild } }

    init(
        layerKinds: [CBv2LayerKind] = [],
        capabilities: CBv2ModelCapabilities = CBv2ModelCapabilities(),
        loadedModelType: String = "stub_test"
    ) {
        self.layerKinds = layerKinds
        self.capabilities = capabilities
        self.loadedModelType = loadedModelType
    }

    var manifest: RunnerManifest {
        RunnerManifest(
            runnerID: Self.manifest.runnerID,
            modelTypes: Self.manifest.modelTypes,
            engine: capabilities,
            kvBackends: Self.manifest.kvBackends,
            decoders: Self.manifest.decoders,
            regimes: Self.manifest.regimes,
            multimodal: Self.manifest.multimodal,
            recurrentLayers: Self.manifest.recurrentLayers,
            requiresKeepMask: Self.manifest.requiresKeepMask)
    }

    static func adopt(
        model: any LanguageModel,
        tokenizer: any MLXLMCommon.Tokenizer,
        configuration: ModelConfiguration,
        directory: URL,
        options: RunnerLoadOptions
    ) throws -> StubRunner {
        StubRunner()
    }

    static func loadDrafter(
        options: RunnerLoadOptions,
        directory: URL,
        target: any LanguageModel
    ) async throws -> (any CBv2MTPDrafter)? { options.preloadedDrafter }

    func makeEngine(_ build: EngineBuild) throws -> any CBv2Engine {
        lock.withLock { _receivedBuild = build }
        return engine
    }

    func makeStepper() throws -> any TeacherForcedStepper {
        throw RunnerError.invalidCheckpoint("stub runner has no stepper")
    }
}

final class StubRunnerModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}
