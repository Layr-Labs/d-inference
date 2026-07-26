import ArgumentParser
import Foundation
import ProviderCore
import ProviderBenchmark

extension Benchmark {
    /// The `--kv-backend` selection, for EVERY mode that builds an engine.
    ///
    /// The flag is declared on the command, not on the sweep, so all three
    /// modes have always accepted it — but only the sweep used to read it,
    /// which meant `--scheduler-prefill` and `--arrival-invariance` silently
    /// took the `.auto` default while the sweep beside them measured what was
    /// asked for. `.auto` resolves CONTIGUOUS, so those two phases measured
    /// the OTHER arm of a paged run and said nothing about it.
    func resolvedKVBackendSelection() throws -> EngineV2KVBackendSelection {
        guard let backend = EngineV2KVBackendSelection(
            rawValue: kvBackend.trimmingCharacters(in: .whitespaces).lowercased())
        else {
            printError("--kv-backend must be one of: auto, contiguous, paged")
            throw ExitCode.failure
        }
        return backend
    }

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
        let backend = try resolvedKVBackendSelection()

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
            backend: backend, failure: report.decodeConstructionFailure,
            coverage: report.decodeCoverage)
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
    /// The same holds one cell at a time. Every batch size builds its own
    /// engine sized by its own `maxConcurrentRequests`, which feeds paged
    /// physical-capacity planning, so `--batch-sizes 1,2,4,8` can resolve
    /// paged at B=1 and refuse at B=8 for want of a concurrency-sized pool.
    /// `decodeConstructionFailure` stays nil there (something ran), the
    /// refused cell contributes a zero to the curve, and the operator named
    /// a cell that silently did not happen. The release headline number is
    /// B=8, so that is precisely the cell a capacity regression takes out.
    ///
    /// Only for an EXPLICIT `--kv-backend`. `auto` keeps its old behaviour
    /// exactly: it promised nothing about the backend, so a degraded or
    /// unbuildable cell is an ordinary bad run rather than a broken
    /// guarantee, and scripts pinned to today's exit status must not start
    /// failing. That asymmetry is the one
    /// `EngineV2KVBackendPolicy.degradesPagedFailure` already encodes for
    /// the engine; this is the same rule at the benchmark's exit status.
    ///
    /// The message names the REASON, not just the count: "no decode cells"
    /// alone sends the reader back to the stderr log to find out why.
    static func sweepFailureMessage(
        backend: EngineV2KVBackendSelection,
        failure: ThroughputSweepReport.DecodeConstructionFailure?,
        coverage: ThroughputSweepReport.DecodeCoverage = .init(
            requestedBatchSizes: [], unmeasured: [])
    ) -> String? {
        guard backend != .auto else { return nil }
        if let failure {
            return "--kv-backend \(backend.rawValue) produced no decode cells: "
                + failure.reason
        }
        guard !coverage.unmeasured.isEmpty else { return nil }
        let cells = coverage.unmeasured
            .map { "B=\($0.batchSize): \($0.reason)" }
            .joined(separator: "; ")
        return "--kv-backend \(backend.rawValue) left "
            + "\(coverage.unmeasured.count) of \(coverage.requestedBatchSizes.count) "
            + "requested decode cells unmeasured — \(cells)"
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
            iterations: prefillIterations,
            kvBackend: try resolvedKVBackendSelection()
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
            iterations: arrivalIterations,
            kvBackend: try resolvedKVBackendSelection()
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
