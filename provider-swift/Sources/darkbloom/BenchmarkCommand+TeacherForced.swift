import ArgumentParser
import Foundation
import ProviderBenchmark
import ProviderCore

extension Benchmark {
    func runTeacherForcedScoring(
        modelID: String, modelDirectory: URL, inputPath: String,
        gemmaOptimizations: GemmaOptimizationSettings
    ) async throws {
        let result = try await TeacherForcedBenchmark.run(
            modelID: modelID, modelDirectory: modelDirectory,
            inputURL: URL(fileURLWithPath: inputPath), backend: kvBackend,
            kvQuantization: try resolvedKVQuantizationSelection(),
            gemmaOptimizations: gemmaOptimizations)
        // Preserve nonfinite/neutrality evidence even when inconclusive.
        print(result.json)
        if !result.controlsPassed { throw ExitCode(2) }
    }
}
