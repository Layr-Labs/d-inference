import Foundation
import Testing
@testable import ProviderBenchmark

@Suite("Runtime-generation native owner exclusion")
struct RuntimeGenerationBenchmarkTests {
    @Test func miMoIsRefusedBeforeLoadingOrGPUExecution() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"model_type":"mimo_v2"}"#.utf8)
            .write(to: directory.appendingPathComponent("config.json"))
        await #expect(throws: RuntimeGenerationBenchmark.Failure.unsupportedMiMo) {
            try await RuntimeGenerationBenchmark.run(modelID: "arbitrary-alias", modelDirectory: directory,
                prompt: "Public fixture", maxTokens: 1, backend: "paged", renderDate: "2026-10-09")
        }
    }
}
