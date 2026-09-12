import Foundation
import Testing

@testable import ProviderCore

@Suite("Nemotron standalone load admission", .serialized)
struct NemotronStandaloneAdmissionTests {
    private struct ReachedWeightLoad: Error {}

    @Test("Qualified Lightning reaches weight loading instead of type-only rejection", arguments: [
        "mlx-community/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-4bit",
        "nvidia-nemotron-3.5-lightning",
        "EigenLabs/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-MLX-4bit-mtp",
        "nvidia-nemotron-3.5-lightning-hybrid8",
        "nvidia-nemotron-3.5-lightning-4bit-r1",
    ])
    func qualifiedArtifactReachesLoad(modelID: String) async throws {
        // Only path resolution is needed: stop before reading any weights.
        // Reuse existing snapshots without modifying them; otherwise own only
        // a uniquely named empty snapshot, never the user's model directory.
        var ownedSnapshot: URL?
        if ModelScanner.resolveLocalPath(modelID: modelID) == nil {
            let cache = try #require(ModelScanner.defaultCacheDirectory())
            let snapshot = cache
                .appendingPathComponent("models--" + modelID.replacingOccurrences(of: "/", with: "--"))
                .appendingPathComponent("snapshots")
                .appendingPathComponent("admission-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
            ownedSnapshot = snapshot
            try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        }
        defer {
            if let ownedSnapshot { try? FileManager.default.removeItem(at: ownedSnapshot) }
        }

        let server = StandaloneServer(
            config: .init(mtpMode: .off),
            models: [.init(id: modelID, modelType: "nemotron_h", sizeBytes: 1, estimatedMemoryGb: 0.25)])
        await server.setV2TestHooksForTesting(.init(
            beforeWeightLoad: { _ in throw ReachedWeightLoad() },
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))
        do {
            try await server.ensureModelLoaded(modelID)
            Issue.record("The observation hook should stop weight loading")
        } catch is ReachedWeightLoad {
            // Success: actual standalone loading passed the qualified-ID guard.
        }
        #expect(await server.debugOutstandingKVReservationBytes() == 0)
    }

    @Test("Unqualified Nano sharing nemotron_h remains rejected")
    func nanoRemainsRejected() async throws {
        let modelID = "mlx-community/NVIDIA-Nemotron-Nano"
        let server = StandaloneServer(
            config: .init(mtpMode: .off),
            models: [.init(id: modelID, modelType: "nemotron_h", sizeBytes: 1, estimatedMemoryGb: 0.25)])
        do {
            try await server.ensureModelLoaded(modelID)
            Issue.record("Nano must remain outside the qualified serving set")
        } catch StandaloneServerError.modelNotFound(let rejectedID) {
            #expect(rejectedID == modelID)
        }
    }
}
