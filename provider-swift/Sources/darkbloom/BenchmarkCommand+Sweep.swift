import ArgumentParser
import Foundation
import ProviderCore
import ProviderBenchmark

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
        guard decodeIterations >= 1 else {
            printError("--decode-iterations must be >= 1")
            throw ExitCode.failure
        }
        // An explicit list wins over the ladder: the release gates need the
        // cells {1,2,4,8}, not every integer up to 8.
        let batches: [Int]
        if let raw = batchSizes {
            batches = Self.parsePositiveInts(raw)
            guard !batches.isEmpty else {
                printError("--batch-sizes must contain at least one positive integer")
                throw ExitCode.failure
            }
        } else {
            guard maxBatch >= 1 else {
                printError("--max-batch must be >= 1")
                throw ExitCode.failure
            }
            batches = Array(1 ... maxBatch)
        }
        guard let backend = EngineV2KVBackendSelection(
            rawValue: kvBackend.trimmingCharacters(in: .whitespaces).lowercased())
        else {
            printError("--kv-backend must be one of: auto, contiguous, paged")
            throw ExitCode.failure
        }

        let report = try await ThroughputSweep.run(
            modelID: modelID,
            modelDirectory: modelDirectory,
            promptLengths: lengths,
            batchSizes: batches,
            decodeTokens: decodeTokens,
            decodePromptTokens: decodePromptTokens,
            decodeIterations: decodeIterations,
            kvBackend: backend,
            hardware: hardware
        )

        // The artifact ALWAYS ships, including on a refused run: the operator
        // needs the notes line and the failure reason more than the status,
        // and swallowing the report to signal an error would trade a good
        // diagnostic for a bad one.
        print(try report.jsonString())

        if let message = Self.sweepFailureMessage(
            backend: backend, failure: report.decodeConstructionFailure)
        {
            printError(message)
            throw ExitCode.failure
        }
    }

    /// Exit-status decision for a completed sweep: the message to print
    /// before failing, or nil when the run may report success.
    ///
    /// A sweep that constructed no engine measured NOTHING. Exiting 0 there
    /// is indistinguishable from success to `set -e`, to CI, and to any
    /// wrapper that checks status before parsing the report — and with no
    /// canary fleet this benchmark IS the safety net for the paged rollout,
    /// so it must not report success on total failure.
    ///
    /// Only for an EXPLICIT `--kv-backend`. `auto` keeps its old behaviour
    /// exactly: it promised nothing about the backend, so a run that could
    /// not build one is an ordinary bad run rather than a broken guarantee,
    /// and scripts pinned to today's exit status must not start failing.
    ///
    /// The message names the REASON, not just the count: "no decode cells"
    /// alone sends the reader back to the stderr log to find out why.
    static func sweepFailureMessage(
        backend: EngineV2KVBackendSelection,
        failure: ThroughputSweepReport.DecodeConstructionFailure?
    ) -> String? {
        guard backend != .auto, let failure else { return nil }
        return "--kv-backend \(backend.rawValue) produced no decode cells: "
            + failure.reason
    }

    func runSchedulerPrefillBenchmark(
        modelID: String,
        modelDirectory: URL
    ) async throws {
        let lengths = Self.parsePositiveInts(prefillLengths)
        guard !lengths.isEmpty else {
            printError("--prefill-lengths must contain at least one positive integer")
            throw ExitCode.failure
        }
        guard prefillIterations >= 1 else {
            printError("--prefill-iterations must be >= 1")
            throw ExitCode.failure
        }

        let report = try await SchedulerPrefillBenchmark.run(
            modelID: modelID,
            modelDirectory: modelDirectory,
            promptLengths: lengths,
            iterations: prefillIterations
        )

        print(try report.jsonString())
    }

    func runArrivalInvarianceBenchmark(
        modelID: String,
        modelDirectory: URL
    ) async throws {
        guard arrivalPromptTokens >= 2 else {
            printError("--arrival-prompt-tokens must be >= 2")
            throw ExitCode.failure
        }
        guard arrivalDecodeTokens >= 2 else {
            printError("--arrival-decode-tokens must be >= 2")
            throw ExitCode.failure
        }
        guard arrivalIterations >= 1 else {
            printError("--arrival-iterations must be >= 1")
            throw ExitCode.failure
        }

        let report = try await ArrivalInvarianceBenchmark.run(
            modelID: modelID,
            modelDirectory: modelDirectory,
            promptTokens: arrivalPromptTokens,
            decodeTokens: arrivalDecodeTokens,
            iterations: arrivalIterations
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
