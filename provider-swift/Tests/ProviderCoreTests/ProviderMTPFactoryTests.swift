import Foundation
import Crypto
import MLX
import MLXLMCommon
import MLXNN
import Testing
@testable import ProviderCore
import ProviderCoreFoundation

private struct MTPFactoryTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [0] }
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
    ) throws -> [Int] { [0] }
}

private final class MTPFactoryTarget: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct MTPFactoryProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput { throw CancellationError() }
}

private func mtpFactoryContainer(_ target: MTPFactoryTarget = MTPFactoryTarget()) -> ModelContainer {
    ModelContainer(context: ModelContext(
        configuration: ModelConfiguration(id: "test/mtp-factory"),
        model: target,
        processor: MTPFactoryProcessor(),
        tokenizer: MTPFactoryTokenizer()))
}

private func mtpFactoryArtifact() throws -> SpecDecArtifact {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-mtp-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{"model_type":"gemma4_assistant"}"#.utf8)
        .write(to: directory.appendingPathComponent("config.json"))
    try Data(repeating: 0x5a, count: 4096)
        .write(to: directory.appendingPathComponent("model.safetensors"))
    return try #require(SpecDecStore.inspectLocalArtifact(path: directory.path))
}

private func mtpSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func mtpCatalogArtifact() throws -> SpecDecArtifact {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-mtp-catalog-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let config = Data(#"{"model_type":"gemma4_assistant"}"#.utf8)
    let weights = Data(repeating: 0x6b, count: 4096)
    try config.write(to: directory.appendingPathComponent("config.json"))
    try weights.write(to: directory.appendingPathComponent("model.safetensors"))
    var aggregate = SHA256()
    for data in [config, weights] {
        SHA256.hash(data: data).withUnsafeBytes { aggregate.update(bufferPointer: $0) }
    }
    let prefix = "v2-specdec/provider-factory/v1"
    let manifest = ModelManifest(
        schemaVersion: 1,
        modelID: "darkbloom/gemma4-assistant",
        version: "v1",
        r2Prefix: prefix,
        aggregateSHA256: aggregate.finalize().map { String(format: "%02x", $0) }.joined(),
        totalSizeBytes: Int64(config.count + weights.count),
        fileCount: 2,
        files: [
            .init(
                path: "config.json", sizeBytes: Int64(config.count),
                sha256: mtpSHA256(config), role: "config"),
            .init(
                path: "model.safetensors", sizeBytes: Int64(weights.count),
                sha256: mtpSHA256(weights), role: "weight"),
        ],
        createdAt: Date(timeIntervalSince1970: 0))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let manifestData = try encoder.encode(manifest)
    try manifestData.write(to: directory.appendingPathComponent("manifest.json"))
    let reference = SpecDecArtifactReference(
        r2Prefix: prefix,
        manifestSHA256: mtpSHA256(manifestData),
        expectedTotalBytes: UInt64(manifest.totalSizeBytes),
        expectedFileCount: manifest.fileCount,
        maximumFileCount: 8,
        allowedFileRoles: ["config", "weight"],
        configSHA256: mtpSHA256(config),
        revision: manifest.version)
    let verification = try SpecDecStore.verifyPublishedArtifact(
        at: directory, reference: reference).get()
    return SpecDecArtifact(
        directory: directory,
        source: .catalog,
        revision: manifest.version,
        artifactBytes: verification.artifactBytes,
        residentBytes: SpecDecLimits.residentEstimate(
            artifactBytes: verification.artifactBytes),
        manifestSHA256: verification.manifestSHA256,
        catalogReference: reference)
}

private final class MTPFactoryPrepared: CBv2MTPPreparedCapture {}
private final class MTPFactoryDrafter: CBv2MTPDrafter, @unchecked Sendable {
    func prepare(rows: [CBv2MTPRowCapture]) -> CBv2MTPPreparedCapture {
        MTPFactoryPrepared()
    }
    func draftStep(
        tokens: MLXArray, hidden: MLXArray, prepared: CBv2MTPPreparedCapture
    ) -> (tokens: MLXArray, hidden: MLXArray) {
        (tokens, hidden)
    }
}

private final class MTPFactoryIdentityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ObjectIdentifier?
    private var calls = 0
    func record(_ target: any LanguageModel) {
        lock.withLock {
            value = ObjectIdentifier(target)
            calls += 1
        }
    }
    var snapshot: (ObjectIdentifier?, Int) { lock.withLock { (value, calls) } }
}

private struct MTPFactoryRecordingLoader: ProviderMTPAssistantLoading {
    let recorder: MTPFactoryIdentityRecorder
    let failure: ProviderMTPAssistantLoadError?

    func loadAndBind(
        artifact: SpecDecArtifact, target: any LanguageModel
    ) async throws -> ProviderMTPAssistantHandle {
        recorder.record(target)
        if let failure { throw failure }
        return ProviderMTPAssistantHandle(
            owner: NSObject(), drafter: MTPFactoryDrafter())
    }
}

private actor MTPFreshProcessCatalog: SpecDecCatalogLooking {
    let modelValue: CatalogModel
    private var warmed = false

    init(model: CatalogModel) { self.modelValue = model }

    func cachedModel(id: String) -> CatalogModel? { warmed ? modelValue : nil }

    func model(id: String) async throws -> CatalogModel? {
        warmed = true
        return modelValue
    }
}

@Suite("Provider MTP target/assistant preparation")
struct ProviderMTPFactoryTests {
    @Test("fresh-process catalog prewarm activates a verified cached assistant on first load")
    func freshProcessCachedCatalogAssistantActivates() async throws {
        let staged = try mtpCatalogArtifact()
        defer { try? FileManager.default.removeItem(at: staged.directory) }
        let reference = try #require(staged.catalogReference)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-mtp-fresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let published = SpecDecStore.artifactDirectory(
            root: root, r2Prefix: reference.r2Prefix)
        try FileManager.default.moveItem(at: staged.directory, to: published)

        let model = CatalogModel(
            id: "gemma-4-test", s3Name: "unused", displayName: "Gemma", sizeGb: 1,
            metadata: ["spec_dec": .object([
                ("r2_prefix", .string(reference.r2Prefix)),
                ("manifest_sha256", .string(reference.manifestSHA256)),
                ("total_size_bytes", .int(Int64(reference.expectedTotalBytes))),
                ("file_count", .int(Int64(reference.expectedFileCount))),
                ("max_file_count", .int(Int64(reference.maximumFileCount))),
                ("allowed_file_types", .array([.string("config"), .string("weight")])),
                ("config_sha256", .string(reference.configSHA256)),
                ("revision", .string(reference.revision)),
            ])])
        let catalog = MTPFreshProcessCatalog(model: model)
        let funnel = SpecDecArtifactFunnel(
            resolver: SpecDecResolver(storeRoot: root), catalog: catalog)

        #expect(await funnel.prewarmCatalog(modelId: model.id, timeout: .seconds(1)))
        let preparation = await funnel.prepare(.init(
            modelId: model.id, modelType: "gemma4", enabled: true,
            localPath: nil, allowDownload: true, environment: [:]))
        #expect(preparation.artifact?.source == .catalog)

        let recorder = MTPFactoryIdentityRecorder()
        let prepared = try await EngineV2SlotFactory.prepareProductionModel(
            modelId: model.id,
            isVLM: false,
            modelDirectory: nil,
            container: mtpFactoryContainer(),
            specDecPreparation: preparation,
            assistantLoader: MTPFactoryRecordingLoader(recorder: recorder, failure: nil))
        #expect(prepared.mtpStatus.active)
        #expect(prepared.assistant != nil)
        #expect(recorder.snapshot.1 == 1)
        prepared.assistant?.release()
        await funnel.shutdown()
    }

    @Test("one exact serving target instance is handed to assistant loader")
    func exactTargetInstance() async throws {
        let target = MTPFactoryTarget()
        let recorder = MTPFactoryIdentityRecorder()
        let artifact = try mtpFactoryArtifact()
        defer { try? FileManager.default.removeItem(at: artifact.directory) }
        let prepared = try await EngineV2SlotFactory.prepareProductionModel(
            modelId: "gemma-4-test",
            isVLM: false,
            modelDirectory: nil,
            container: mtpFactoryContainer(target),
            specDecPreparation: .init(
                artifact: artifact, status: .candidate(artifact)),
            assistantLoader: MTPFactoryRecordingLoader(
                recorder: recorder, failure: nil))
        #expect(recorder.snapshot.0 == ObjectIdentifier(target))
        #expect(recorder.snapshot.1 == 1)
        #expect(ObjectIdentifier(prepared.servingModel) == ObjectIdentifier(target))
        #expect(prepared.mtpStatus.active)
        #expect(prepared.assistantBytes == artifact.residentBytes)
    }

    @Test("assistant load and bind failures are stable target-only fallbacks")
    func loadAndBindFallbacks() async throws {
        for failure in [
            ProviderMTPAssistantLoadError.loadFailed("fixture"),
            ProviderMTPAssistantLoadError.bindFailed("fixture"),
        ] {
            let recorder = MTPFactoryIdentityRecorder()
            let artifact = try mtpFactoryArtifact()
            defer { try? FileManager.default.removeItem(at: artifact.directory) }
            let prepared = try await EngineV2SlotFactory.prepareProductionModel(
                modelId: "gemma-4-test",
                isVLM: false,
                modelDirectory: nil,
                container: mtpFactoryContainer(),
                specDecPreparation: .init(
                    artifact: artifact, status: .candidate(artifact)),
                assistantLoader: MTPFactoryRecordingLoader(
                    recorder: recorder, failure: failure))
            #expect(prepared.assistant == nil)
            #expect(prepared.assistantBytes == 0)
            #expect(prepared.mtpStatus.reason == failure.reason)
        }
    }

    @Test("cached catalog bytes are revalidated on every load and rebuild")
    func cachedCatalogCorruptionFallsBackBeforeLoader() async throws {
        let artifact = try mtpCatalogArtifact()
        defer { try? FileManager.default.removeItem(at: artifact.directory) }
        let firstRecorder = MTPFactoryIdentityRecorder()
        let first = try await EngineV2SlotFactory.prepareProductionModel(
            modelId: "gemma-4-test",
            isVLM: false,
            modelDirectory: nil,
            container: mtpFactoryContainer(),
            specDecPreparation: .init(
                artifact: artifact, status: .candidate(artifact)),
            assistantLoader: MTPFactoryRecordingLoader(
                recorder: firstRecorder, failure: nil))
        #expect(first.assistant != nil)
        #expect(firstRecorder.snapshot.1 == 1)
        first.assistant?.release()

        let weightURL = artifact.directory.appendingPathComponent("model.safetensors")
        var corrupted = try Data(contentsOf: weightURL)
        corrupted[corrupted.startIndex] ^= 0xff
        try corrupted.write(to: weightURL)

        let rebuildRecorder = MTPFactoryIdentityRecorder()
        let rebuilt = try await EngineV2SlotFactory.prepareProductionModel(
            modelId: "gemma-4-test",
            isVLM: false,
            modelDirectory: nil,
            container: mtpFactoryContainer(),
            specDecPreparation: .init(
                artifact: artifact, status: .candidate(artifact)),
            assistantLoader: MTPFactoryRecordingLoader(
                recorder: rebuildRecorder, failure: nil))
        #expect(rebuilt.assistant == nil)
        #expect(rebuilt.assistantBytes == 0)
        #expect(rebuilt.mtpStatus.reason == .warmArtifactCorrupt)
        #expect(rebuildRecorder.snapshot.1 == 0)
    }

    @Test("local override growth after admission falls back before loader")
    func localGrowthFallsBackBeforeLoader() async throws {
        let artifact = try mtpFactoryArtifact()
        defer { try? FileManager.default.removeItem(at: artifact.directory) }
        let weightURL = artifact.directory.appendingPathComponent("model.safetensors")
        let handle = try FileHandle(forWritingTo: weightURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0xff]))
        try handle.close()

        let recorder = MTPFactoryIdentityRecorder()
        let prepared = try await EngineV2SlotFactory.prepareProductionModel(
            modelId: "gemma-4-test",
            isVLM: false,
            modelDirectory: nil,
            container: mtpFactoryContainer(),
            specDecPreparation: .init(
                artifact: artifact, status: .candidate(artifact)),
            assistantLoader: MTPFactoryRecordingLoader(
                recorder: recorder, failure: nil))
        #expect(prepared.assistant == nil)
        #expect(prepared.assistantBytes == 0)
        #expect(prepared.mtpStatus.reason == .localArtifactInvalid)
        #expect(recorder.snapshot.1 == 0)
    }

    @Test("local override same-size weight mutation falls back before loader")
    func localSameSizeMutationFallsBackBeforeLoader() async throws {
        let artifact = try mtpFactoryArtifact()
        defer { try? FileManager.default.removeItem(at: artifact.directory) }
        let weightURL = artifact.directory.appendingPathComponent("model.safetensors")
        var weights = try Data(contentsOf: weightURL)
        weights[weights.startIndex] ^= 0xff
        try weights.write(to: weightURL)

        let recorder = MTPFactoryIdentityRecorder()
        let prepared = try await EngineV2SlotFactory.prepareProductionModel(
            modelId: "gemma-4-test",
            isVLM: false,
            modelDirectory: nil,
            container: mtpFactoryContainer(),
            specDecPreparation: .init(
                artifact: artifact, status: .candidate(artifact)),
            assistantLoader: MTPFactoryRecordingLoader(
                recorder: recorder, failure: nil))
        #expect(prepared.assistant == nil)
        #expect(prepared.assistantBytes == 0)
        #expect(prepared.mtpStatus.reason == .localArtifactInvalid)
        #expect(recorder.snapshot.1 == 0)
    }

    @Test("real loader rejects non-Gemma target without touching artifact files")
    func realLoaderTargetMismatchFailsOpen() async throws {
        let artifact = try mtpFactoryArtifact()
        defer { try? FileManager.default.removeItem(at: artifact.directory) }
        let prepared = try await EngineV2SlotFactory.prepareProductionModel(
            modelId: "gemma-4-test",
            isVLM: false,
            modelDirectory: nil,
            container: mtpFactoryContainer(),
            specDecPreparation: .init(
                artifact: artifact, status: .candidate(artifact)))
        #expect(prepared.assistant == nil)
        #expect(prepared.mtpStatus.reason == .assistantTargetIncompatible)
    }

    @Test("default-off preparation is identity and never calls loader")
    func defaultOffIdentity() async throws {
        let recorder = MTPFactoryIdentityRecorder()
        let prepared = try await EngineV2SlotFactory.prepareProductionModel(
            modelId: "gemma-4-test",
            isVLM: false,
            modelDirectory: nil,
            container: mtpFactoryContainer(),
            specDecPreparation: .init(
                artifact: nil,
                status: .disabled(.configDisabled, configured: false)),
            assistantLoader: MTPFactoryRecordingLoader(
                recorder: recorder, failure: nil))
        #expect(prepared.assistant == nil)
        #expect(prepared.mtpStatus == .disabled(.configDisabled, configured: false))
        #expect(recorder.snapshot.1 == 0)
    }

    @Test("bridge exposes stable read-only activation snapshot")
    func publicStatusSnapshot() async throws {
        let bridge = makeInertStubBridge(modelId: "gemma-4-status").bridge
        let artifact = try mtpFactoryArtifact()
        defer { try? FileManager.default.removeItem(at: artifact.directory) }
        await bridge.configureMTPStatus(
            MTPActivationStatus.candidate(artifact).fallingBack(.assistantLoadFailed),
            metricsInterval: .zero)
        let snapshot = await bridge.mtpStatusSnapshot()
        #expect(snapshot.configured)
        #expect(!snapshot.active)
        #expect(snapshot.fallbackReason == .assistantLoadFailed)
        #expect(snapshot.assistantSource == .local)
        #expect(snapshot.assistantRevision == artifact.revision)
        #expect(snapshot.assistantArtifactBytes == artifact.artifactBytes)
        #expect(snapshot.assistantResidentBytes == 0)
        #expect(snapshot.selectedDepth == 0)
        #expect(snapshot.proposedTokens == 0)
        await bridge.shutdown()
    }

    @Test("bridge and bundle explicitly release engine and assistant ownership")
    func explicitLifetimeRelease() async throws {
        var engine: InertStubEngine? = InertStubEngine()
        weak var weakEngine = engine
        let bridge = EngineV2Bridge(
            engine: try #require(engine),
            modelId: "gemma-4-lifetime",
            tokenizer: TokenizerHandle(StubBridgeTokenizer()),
            eosTokenIds: [])
        engine = nil

        var owner: NSObject? = NSObject()
        weak var weakOwner = owner
        let assistant = ProviderMTPAssistantHandle(
            owner: try #require(owner), drafter: MTPFactoryDrafter())
        owner = nil
        let artifact = try mtpFactoryArtifact()
        defer { try? FileManager.default.removeItem(at: artifact.directory) }
        let bundle = ProviderEngineBundle(
            bridge: bridge,
            assistant: assistant,
            assistantBytes: artifact.residentBytes,
            mtpArtifact: artifact,
            mtpStatus: .candidate(artifact).activated(
                assistantBytes: artifact.residentBytes))

        #expect(weakEngine != nil)
        #expect(weakOwner != nil)
        await bridge.shutdown()
        bundle.releaseAssistant()
        #expect(weakEngine == nil)
        #expect(weakOwner == nil)
    }
}
