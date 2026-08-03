import ArgumentParser
import Foundation
import ProviderBenchmark
import ProviderCore

extension Benchmark {
    /// Drive `BackendParityHarness` for the resolved model and print the JSON
    /// report to stdout. The operator table and all progress go to stderr, so
    /// stdout stays a single parseable JSON document — same contract as
    /// `--sweep`.
    func runBackendParity(
        modelID: String,
        modelDirectory: URL
    ) async throws {
        guard parityMaxTokens >= 1 else {
            printError("--parity-max-tokens must be >= 1")
            throw ExitCode.failure
        }
        guard parityPrefixTokens >= 1 else {
            printError("--parity-prefix-tokens must be >= 1")
            throw ExitCode.failure
        }

        // The assistant is optional: without it the MTP criterion reports
        // UNAVAILABLE (with that as the reason) instead of silently passing.
        var assistantDirectory: URL?
        if let assistantModel {
            guard let resolved = ModelScanner.resolveLocalPath(modelID: assistantModel) else {
                printError("could not resolve local path for assistant '\(assistantModel)'")
                throw ExitCode.failure
            }
            assistantDirectory = resolved
        }

        let report = try await BackendParityHarness.run(
            modelID: modelID,
            modelDirectory: modelDirectory,
            assistantModelID: assistantModel,
            assistantDirectory: assistantDirectory,
            configuration: BackendParityHarness.Configuration(
                maxTokens: parityMaxTokens,
                prefixProbePromptTokens: parityPrefixTokens))

        // The artifact ALWAYS ships, including on a failing or inconclusive
        // run: the per-criterion detail is the point of the gate, and
        // swallowing it to signal an error would trade a good diagnostic for
        // a bad one.
        print(try report.jsonString())
        printError(report.renderTable())

        let status = Self.parityExitStatus(report)
        guard status == 0 else { throw ExitCode(status) }
    }

    /// Exit-status decision for a completed parity run.
    ///
    /// Three distinguishable statuses, deliberately. `--sweep` shipped a bug
    /// this wave where a run that measured NOTHING still exited 0, which to
    /// `set -e` and to CI is indistinguishable from success. With no canary
    /// fleet this gate is the paged rollout's safety net, so "everything was
    /// skipped" gets its own status (2) rather than borrowing either
    /// neighbour's meaning.
    static func parityExitStatus(_ report: BackendParityReport) -> Int32 {
        report.outcome.exitStatus
    }
}
