import Foundation
import Testing
@testable import ProviderCore

private actor StandaloneMTPCatalogProbe: SpecDecCatalogLooking {
    private(set) var calls = 0
    func cachedModel(id: String) -> CatalogModel? { nil }
    func model(id: String) async throws -> CatalogModel? {
        calls += 1
        return nil
    }
}

@Test func standaloneAssistantCatalogUsesConfiguredCoordinatorAuthority() {
    #expect(StandaloneServerConfig().coordinatorURL == CoordinatorSettings().url)
    let custom = "ws://127.0.0.1:19999/ws/provider"
    #expect(StandaloneServerConfig(coordinatorURL: custom).coordinatorURL == custom)
}

@Test func standaloneAutomaticQATAssistantSchedulesCatalogWithoutBlockingTargetPreparation() async throws {
    let catalog = StandaloneMTPCatalogProbe()
    let funnel = SpecDecArtifactFunnel(resolver: SpecDecResolver(), catalog: catalog)
    let server = StandaloneServer(config: .init(mtpMode: .auto))
    await server.setSpecDecFunnelForTesting(funnel)
    let model = ModelInfo(id: "gemma-4-26b-qat-4bit", modelType: "gemma4",
        quantization: "4bit", sizeBytes: 1, estimatedMemoryGb: 1)
    let result = await server.specDecPreparation(modelId: model.id, modelInfo: model)
    #expect(result.artifact == nil)
    #expect(result.status.configured)
    for _ in 0..<100 {
        if await catalog.calls == 1 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await catalog.calls == 1)
    await funnel.shutdown()
}

@Test func standaloneOffAndOtherAutomaticGemmaDoNotFetchAssistants() async {
    for (mode, id) in [(MTPMode.off, "gemma-4-26b-qat-4bit"), (.auto, "gemma-4-26b-8bit")] {
        let catalog = StandaloneMTPCatalogProbe()
        let funnel = SpecDecArtifactFunnel(resolver: SpecDecResolver(), catalog: catalog)
        let server = StandaloneServer(config: .init(mtpMode: mode))
        await server.setSpecDecFunnelForTesting(funnel)
        let model = ModelInfo(id: id, modelType: "gemma4",
            quantization: "4bit", sizeBytes: 1, estimatedMemoryGb: 1)
        let result = await server.specDecPreparation(modelId: model.id, modelInfo: model)
        #expect(result.artifact == nil)
        #expect(!result.status.configured)
        #expect(await catalog.calls == 0)
        await funnel.shutdown()
    }
}
