import Foundation
import ProviderCore

extension Benchmark {
    func modelDirectoryOptionError() -> String? {
        guard let modelDirectory else { return nil }
        guard !modelDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "--model-directory requires a directory and explicit --model"
        }
        let supportedModes = [teacherForcedInput != nil, kvQualityInput != nil, sweep, schedulerPrefill, arrivalInvariance]
        guard !schedulerPrefillDecision, !parity, supportedModes.filter({ $0 }).count == 1 else {
            return "--model-directory requires exactly one of --teacher-forced-input, --kv-quality-input, --sweep, --scheduler-prefill or --arrival-invariance"
        }
        if teacherForcedInput == nil && kvQualityInput == nil {
            guard let expectedModelAggregateSHA256,
                BenchmarkArtifactIdentity.validHash(expectedModelAggregateSHA256) else {
                return BenchmarkArtifactIdentity.Failure.invalidExpectedHash.description
            }
        }
        return nil
    }

    func exactModelDirectoryOverride() -> URL? {
        guard modelDirectoryOptionError() == nil, let modelDirectory else { return nil }
        return URL(fileURLWithPath: modelDirectory, isDirectory: true)
    }

    func measureExactArtifact<Result>(
        modelID: String, directory: URL, operation: () async throws -> Result
    ) async throws -> BenchmarkArtifactIdentity.Measurement<Result> {
        let expected: String?
        if modelDirectory != nil {
            guard let hash = expectedModelAggregateSHA256, BenchmarkArtifactIdentity.validHash(hash) else {
                throw BenchmarkArtifactIdentity.Failure.invalidExpectedHash
            }
            expected = hash
        } else { expected = nil }
        return try await BenchmarkArtifactIdentity.measure(
            modelID: modelID, modelDirectory: directory, expectedHash: expected,
            readHash: { WeightHasher.computeHash(snapshotDir: directory, modelID: modelID) },
            operation: operation)
    }
}
