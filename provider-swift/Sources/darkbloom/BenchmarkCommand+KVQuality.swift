import ArgumentParser
import Foundation
import ProviderBenchmark
import ProviderCore

extension Benchmark {
    func kvQualityOptionError() -> String? {
        guard let kvQualityInput else { return nil }
        guard !kvQualityInput.isEmpty, let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "--kv-quality-input requires a file and explicit --model"
        }
        guard assistantModel == nil, output == nil, expectedModelAggregateSHA256 == nil,
            expectedRegisteredBinarySHA256 == nil, expectedVersion == nil, sourceSHA == nil else {
            return "--kv-quality-input uses input-bound artifact identity, MTP/cache off and JSON stdout; assistant and signed-decision options do not apply"
        }
        do { try TeacherForcedBenchmark.validateBackend(kvBackend) }
        catch { return "--kv-quality-input requires --kv-backend contiguous or paged" }
        return nil
    }

    func runKVQuality(modelID: String, directory: URL, inputPath: String) async throws {
        let result = try await KVQualityBenchmark.run(
            modelID: modelID, modelDirectory: directory, inputURL: URL(fileURLWithPath: inputPath),
            backend: kvBackend, kvQuantization: try resolvedKVQuantizationSelection(),
            quantizedPrefillMode: try resolvedQuantizedPrefillMode())
        print(result.json) // run returns only after the post-measurement hash check
        if !result.controlsPassed { throw ExitCode(2) }
    }
}
