import Foundation
import Testing

@testable import ProviderCore

/// Exercise the production cold-load entry point, without a resident engine or
/// real weight loading. The hook precedes hashing, requireMetal and loadContainer.
/// Standalone initialization/failure cleanup still configures/clears the native
/// allocator, so execute this suite separately from heavyweight model tests.
@Suite("Qwen 3.8 Next standalone load admission", .serialized)
struct Qwen4StandaloneAdmissionTests {
    private struct ReachedWeightLoad: Error {}
    private struct UnexpectedEngineConstruction: Error {}

    @Test("Owned artifact reaches the actual cold-load hook for both native types",
          arguments: ["qwen4_exp", "qwen4_exp_text"])
    func ownedArtifactReachesLoad(modelType: String) async throws {
        let modelID = Qwen4SupportPolicy.ownedModelID
        let snapshot = try Snapshot(modelID: modelID, reuseExisting: true)
        defer { snapshot.removeOwnedFiles() }
        let server = await makeServer(models: [info(modelID, modelType)])

        #expect(await server.advertisedModelIds() == [modelID])
        #expect(EngineV2KVBackendPolicy.preferredBackend(
            selection: .auto, modelID: modelID) == .paged)
        #expect(PrefixCachePolicy.isEnabled(modelId: modelID, environment: [:]))
        try await requireLoadHookAndCleanup(server, modelID: modelID)
        // A second cold attempt also reaches the hook: the failed attempt must
        // leave neither a loading marker/waiter nor a falsely resident slot.
        try await requireLoadHookAndCleanup(server, modelID: modelID)
    }

    @Test("Other native artifacts remain loadable without owned-artifact defaults",
          arguments: ["qwen4_exp", "qwen4_exp_text"])
    func sameArchitectureDoesNotRequireOwnedID(modelType: String) async throws {
        let modelID = uniqueID()
        let snapshot = try Snapshot(modelID: modelID)
        defer { snapshot.removeOwnedFiles() }
        let server = await makeServer(models: [info(modelID, modelType)])

        #expect(await server.advertisedModelIds() == [modelID])
        #expect(!Qwen4SupportPolicy.isOwnedModelID(modelID))
        #expect(EngineV2KVBackendPolicy.preferredBackend(
            selection: .auto, modelID: modelID) == .contiguous)
        #expect(!PrefixCachePolicy.isEnabled(modelId: modelID, environment: [:]))
        try await requireLoadHookAndCleanup(server, modelID: modelID)
    }

    @Test("A local snapshot outside the advertised set cannot enter loading")
    func unknownModelIsRejectedDespiteLocalSnapshot() async throws {
        let modelID = uniqueID()
        let snapshot = try Snapshot(modelID: modelID)
        defer { snapshot.removeOwnedFiles() }
        #expect(ModelScanner.resolveLocalPath(modelID: modelID) != nil)
        let server = await makeServer(models: [])
        try await requireNotFoundAndCleanup(server, modelID: modelID)
    }

    @Test("Advertised native metadata without a local snapshot fails before loading")
    func missingSnapshotIsRejected() async throws {
        let modelID = uniqueID()
        #expect(ModelScanner.resolveLocalPath(modelID: modelID) == nil)
        let server = await makeServer(models: [info(modelID, "qwen4_exp")])
        #expect(await server.advertisedModelIds() == [modelID])
        try await requireNotFoundAndCleanup(server, modelID: modelID)
    }

    @Test("Missing or malformed architecture cannot become a served model", arguments: [
        "missing-config", "malformed-json", "missing-type", "numeric-type", "unsupported-type",
    ])
    func invalidScannedArchitectureIsRejected(fixture: String) async throws {
        let modelID = uniqueID()
        let snapshot = try Snapshot(modelID: modelID)
        defer { snapshot.removeOwnedFiles() }
        let config: String?
        switch fixture {
        case "missing-config": config = nil
        case "malformed-json": config = "{broken"
        case "missing-type": config = "{}"
        case "numeric-type": config = #"{"model_type":4}"#
        default: config = #"{"model_type":"qwen4_exp_other"}"#
        }
        if let config {
            try Data(config.utf8).write(to: snapshot.directory.appendingPathComponent("config.json"))
        }
        // Discovery uses file size, not a tensor load. The deliberate invalid
        // weight payload must never reach the pre-weight observation hook.
        try Data([0]).write(to: snapshot.directory.appendingPathComponent("model.safetensors"))
        let model = try #require(ModelScanner.parseModelInfo(
            snapshotDir: snapshot.directory, modelName: modelID))
        let server = await makeServer(models: [model])
        #expect(await server.advertisedModelIds().isEmpty)
        try await requireNotFoundAndCleanup(server, modelID: modelID)
    }

    @Test("A native config with no weight payload is not discovered or admitted")
    func missingWeightsAreNotDiscovered() async throws {
        let modelID = uniqueID()
        let snapshot = try Snapshot(modelID: modelID)
        defer { snapshot.removeOwnedFiles() }
        try Data(#"{"model_type":"qwen4_exp"}"#.utf8)
            .write(to: snapshot.directory.appendingPathComponent("config.json"))
        let model = ModelScanner.parseModelInfo(snapshotDir: snapshot.directory, modelName: modelID)
        #expect(model == nil)
        let server = await makeServer(models: model.map { [$0] } ?? [])
        try await requireNotFoundAndCleanup(server, modelID: modelID)
    }

    @Test("The owned name never overrides an unsupported architecture")
    func ownedIDDoesNotOverrideUnsupportedType() async throws {
        let modelID = Qwen4SupportPolicy.ownedModelID
        let server = await makeServer(models: [info(modelID, "llama")])
        #expect(await server.advertisedModelIds().isEmpty)
        try await requireNotFoundAndCleanup(server, modelID: modelID)
    }

    private func makeServer(models: [ModelInfo]) async -> StandaloneServer {
        let server = StandaloneServer(config: .init(mtpMode: .off), models: models)
        await server.setV2TestHooksForTesting(.init(
            beforeWeightLoad: { [weak server] modelID in
                let server = try #require(server)
                let budget = await server.kvBudget
                #expect(await budget.reservationExists("pending-load:\(modelID)"))
                #expect(await server.debugOutstandingKVReservationBytes() > 0)
                throw ReachedWeightLoad()
            },
            makeEngine: { _, _ in
                Issue.record("Admission-only test reached engine construction")
                throw UnexpectedEngineConstruction()
            }))
        return server
    }

    private func requireLoadHookAndCleanup(_ server: StandaloneServer, modelID: String) async throws {
        do {
            try await server.ensureModelLoaded(modelID)
            Issue.record("Cold load returned without the observation hook")
        } catch is ReachedWeightLoad {
            // The actual support/path/memory gates and pending-load claim ran.
        }
        await requireClean(server, modelID: modelID)
    }

    private func requireNotFoundAndCleanup(_ server: StandaloneServer, modelID: String) async throws {
        do {
            try await server.ensureModelLoaded(modelID)
            Issue.record("Unservable artifact entered loading")
        } catch StandaloneServerError.modelNotFound(let rejectedID) {
            #expect(rejectedID == modelID)
        }
        await requireClean(server, modelID: modelID)
    }

    private func requireClean(_ server: StandaloneServer, modelID: String) async {
        let budget = await server.kvBudget
        #expect(await budget.reservationIDsForTesting().isEmpty)
        #expect(await server.debugOutstandingKVReservationBytes() == 0)
        #expect(await server.debugSlotReservationCount(modelId: modelID) == 0)
        #expect(await server.debugActiveRequestCount(modelId: modelID) == nil)
        #expect(await server.slots.isEmpty)
        #expect(await server.isLoadingAny == false)
    }

    private func info(_ modelID: String, _ modelType: String) -> ModelInfo {
        .init(id: modelID, modelType: modelType, sizeBytes: 1, estimatedMemoryGb: 0.25)
    }

    private func uniqueID() -> String { "qwen4-admission-fixture/\(UUID().uuidString)" }

    private struct Snapshot {
        let directory: URL
        private let ownedDirectory: URL?

        init(modelID: String, reuseExisting: Bool = false) throws {
            if reuseExisting, let existing = ModelScanner.resolveLocalPath(modelID: modelID) {
                directory = existing
                ownedDirectory = nil
                return
            }
            let cache = try #require(ModelScanner.defaultCacheDirectory())
            let modelRoot = cache.appendingPathComponent(
                "models--" + modelID.replacingOccurrences(of: "/", with: "--"))
            let rootAlreadyExisted = FileManager.default.fileExists(atPath: modelRoot.path)
            directory = modelRoot.appendingPathComponent("snapshots")
                .appendingPathComponent("qwen4-admission-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Unique synthetic IDs own their whole new directory. The canonical
            // owned ID never removes shared ancestors or existing model data.
            ownedDirectory = !reuseExisting && !rootAlreadyExisted ? modelRoot : directory
        }

        func removeOwnedFiles() {
            if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) }
        }
    }
}
