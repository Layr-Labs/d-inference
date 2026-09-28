import Foundation
import Testing

@testable import ProviderCore

private func startupModel(_ id: String) -> ModelInfo {
    ModelInfo(
        id: id, modelType: "gemma4", quantization: "4bit",
        sizeBytes: 1, estimatedMemoryGb: 0.25)
}

@Test("local startup retains selected models in order for slot backfill")
func standaloneStartupPlanUsesSelectedOrder() async {
    let server = StandaloneServer(
        config: StandaloneServerConfig(maxCachedModels: 2),
        models: [startupModel("a"), startupModel("b"), startupModel("c")])

    let plan = await server.startupPreloadPlan(configuredModelIDs: [])
    #expect(plan.map(\.modelId) == ["a", "b", "c"])
    #expect(plan.allSatisfy { $0.requiredGb > 0.25 })

    let explicit = await server.startupPreloadPlan(
        configuredModelIDs: ["c", "missing", "a", "c"])
    #expect(explicit.map(\.modelId) == ["c", "a"])
}

private actor StartupLoadProbe {
    var reachedLoadGate = false
    func record() { reachedLoadGate = true }
}

private struct StopBeforeWeightLoad: Error {}

@Test("local startup begins a real load before any request")
func standaloneStartupAttemptsLoad() async throws {
    let id = "darkbloom-tests/standalone-startup-\(UUID().uuidString.prefix(8))"
    let cacheDir = ModelScanner.defaultCacheDirectory()
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    let modelDir = cacheDir.appendingPathComponent(
        "models--\(id.replacingOccurrences(of: "/", with: "--"))", isDirectory: true)
    let snapshot = modelDir.appendingPathComponent("snapshots/main", isDirectory: true)
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: modelDir) }
    try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))

    let server = StandaloneServer(
        models: [startupModel(id)],
        kvBudgetForTesting: ScriptedProviderMemory.budget(modelIDs: [id]))
    let probe = StartupLoadProbe()
    await server.setV2TestHooksForTesting(.init(
        beforeWeightLoad: { _ in
            await probe.record()
            throw StopBeforeWeightLoad()
        },
        makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))

    let summary = await server.preloadSelectedModels()

    #expect(await probe.reachedLoadGate)
    #expect(summary.failed == [id])
    #expect(summary.loaded.isEmpty)
    #expect(await server.debugOutstandingKVReservationBytes() == 0)
}
