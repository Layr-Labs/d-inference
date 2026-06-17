import ArgumentParser
import Foundation
import ProviderCore

extension Benchmark {
    /// Drive `ThroughputSweep` for the resolved model and print the JSON report
    /// to stdout. Progress lines go to stderr (inside `ThroughputSweep`) so
    /// stdout stays a single parseable JSON document.
    func runThroughputSweep(
        modelID: String,
        modelDirectory: URL,
        hardware: HardwareInfo
    ) async throws {
        let lengths = Self.parsePositiveInts(prefillLengths)
        guard !lengths.isEmpty else {
            printError("--prefill-lengths must contain at least one positive integer")
            throw ExitCode.failure
        }
        guard maxBatch >= 1 else {
            printError("--max-batch must be >= 1")
            throw ExitCode.failure
        }
        let batchSizes = Array(1 ... maxBatch)

        let report = try await ThroughputSweep.run(
            modelID: modelID,
            modelDirectory: modelDirectory,
            promptLengths: lengths,
            batchSizes: batchSizes,
            decodeTokens: decodeTokens,
            decodePromptTokens: decodePromptTokens,
            hardware: hardware
        )

        print(try report.jsonString())
    }

    /// Parse a comma-separated list of positive integers, ignoring blanks and
    /// non-numeric tokens.
    static func parsePositiveInts(_ raw: String) -> [Int] {
        raw.split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 0 }
    }
}
