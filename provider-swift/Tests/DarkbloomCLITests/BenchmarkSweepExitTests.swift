// Copyright © 2026 Eigen Labs.
//
// Exit-status contract for `darkbloom benchmark --sweep`.
//
// A sweep that constructed no engine measured NOTHING. Exiting 0 there is
// indistinguishable from success to `set -e`, to CI, and to any wrapper
// that checks status before parsing the report. With no canary fleet this
// benchmark IS the safety net for the paged rollout (OPEN-9), so a refused
// `--kv-backend paged` run must fail the process, not return an empty
// curve with a green status.
//
// The partial case is the same defect one cell at a time: each batch size
// builds its own engine sized by its own `maxConcurrentRequests`, which
// feeds paged physical-capacity planning, so B=1 can resolve paged while
// B=8 refuses. `decodeConstructionFailure` stays nil (something ran), the
// refused cell contributes a zero to the curve, and a gate that only fires
// when NOTHING ran cannot fail. An explicit `--batch-sizes 1,2,4,8` names
// the cells the operator wants; one of them not happening is a broken
// promise, and the release headline number lives at B=8.
//
// The `auto` half matters just as much: `auto` promised nothing about the
// backend, so a run that could not build one is an ordinary bad run and
// must keep its existing exit status. Widening the failure to `auto` would
// start failing scripts that are green today. That asymmetry is the one
// `EngineV2KVBackendPolicy.degradesPagedFailure` already encodes.

import ArgumentParser
import ProviderBenchmark
import ProviderCore
import Testing

@testable import darkbloom

private func failure(
    _ selection: String = "paged",
    reason: String = "engine_v2: paged KV backend explicitly requested but "
        + "unavailable — kernel_preflight: ineligible head dim"
) -> ThroughputSweepReport.DecodeConstructionFailure {
    .init(kvBackendSelection: selection, reason: reason)
}

private func coverage(
    requested: [Int] = [1, 2, 4, 8],
    unmeasured: [(Int, String)] = [(8, "engine_v2: paged KV backend explicitly "
        + "requested but unavailable — physical_capacity: pool of 8 sequences "
        + "exceeds the resident budget")]
) -> ThroughputSweepReport.DecodeCoverage {
    .init(
        requestedBatchSizes: requested,
        unmeasured: unmeasured.map { .init(batchSize: $0.0, reason: $0.1) })
}

@Suite("benchmark sweep exit status")
struct BenchmarkSweepExitTests {

    @Test("explicit paged with zero decode cells fails and names the reason")
    func explicitPagedFails() throws {
        let message = Benchmark.sweepFailureMessage(
            backend: .paged, failure: failure())
        let text = try #require(message)
        // Names the selection so the operator knows which flag broke...
        #expect(text.contains("--kv-backend paged"))
        // ...and the CAUSE, not just the count. "produced no decode cells"
        // on its own sends the reader back to the stderr log.
        #expect(text.contains("kernel_preflight: ineligible head dim"))
    }

    @Test("explicit contiguous with zero decode cells also fails")
    func explicitContiguousFails() {
        // Not paged-specific: an explicit backend of either kind is a claim
        // the run is measured against.
        let message = Benchmark.sweepFailureMessage(
            backend: .contiguous,
            failure: failure("contiguous", reason: "engine_v2: no KV byte headroom"))
        #expect(message?.contains("--kv-backend contiguous") == true)
        #expect(message?.contains("no KV byte headroom") == true)
    }

    @Test("auto keeps its old exit status even with zero decode cells")
    func autoDoesNotFail() {
        // The narrow scope of the change. `auto` degrades by design; a
        // failed auto run stays exit 0 exactly as it does today.
        #expect(Benchmark.sweepFailureMessage(backend: .auto, failure: failure()) == nil)
    }

    @Test("a sweep that produced cells succeeds for every selection")
    func healthyRunSucceeds() {
        for backend in EngineV2KVBackendSelection.allCases {
            #expect(Benchmark.sweepFailureMessage(backend: backend, failure: nil) == nil)
        }
    }

    @Test("explicit paged fails when a REQUESTED cell went unmeasured")
    func explicitPagedPartialCoverageFails() throws {
        // The finding. `--batch-sizes 1,2,4,8` with B=8 refused: three cells
        // resolved, so `decodeConstructionFailure` is nil and the old
        // "nothing ran" gate could not fire. The zero at B=8 still landed in
        // the curve and the process exited 0 on a cell that never happened.
        let message = Benchmark.sweepFailureMessage(
            backend: .paged, failure: nil, coverage: coverage())
        let text = try #require(message)
        #expect(text.contains("--kv-backend paged"))
        // Names WHICH cell is missing — the release headline number is B=8,
        // and "some cell failed" does not say whether that one did.
        #expect(text.contains("B=8"))
        #expect(text.contains("1 of 4"))
        // ...and WHY, so the operator is not sent back to the stderr log.
        #expect(text.contains("physical_capacity"))
        // A non-nil message is thrown as `ExitCode.failure` by
        // `runThroughputSweep`: process status 1, not 0.
        #expect(ExitCode.failure.rawValue == 1)
    }

    @Test("every unmeasured cell is named, not just the first")
    func partialCoverageNamesEveryCell() throws {
        let text = try #require(Benchmark.sweepFailureMessage(
            backend: .paged, failure: nil,
            coverage: coverage(
                requested: [1, 2, 4, 8],
                unmeasured: [(4, "physical_capacity: pool of 4"),
                             (8, "physical_capacity: pool of 8")])))
        #expect(text.contains("2 of 4"))
        #expect(text.contains("B=4"))
        #expect(text.contains("B=8"))
    }

    @Test("auto with an unmeasured cell still exits 0")
    func autoPartialCoverageSucceeds() {
        // Under `auto` the operator named no backend, so a cell that could
        // not build one is an ordinary bad run, not a broken promise — the
        // same asymmetry `EngineV2KVBackendPolicy.degradesPagedFailure`
        // encodes for the engine. `auto` resolves contiguous as of v0.8.1,
        // so a paged capacity refusal is not reachable here; what is reachable
        // is an ordinary construction error, and it keeps its exit status. The
        // degrade rule remains for any future release that resolves auto paged.
        // Nil message ⇒ `runThroughputSweep` returns normally ⇒ 0.
        #expect(Benchmark.sweepFailureMessage(
            backend: .auto, failure: nil, coverage: coverage()) == nil)
        #expect(ExitCode.success.rawValue == 0)
    }

    @Test("a fully measured sweep succeeds for every selection")
    func fullCoverageSucceeds() {
        for backend in EngineV2KVBackendSelection.allCases {
            #expect(Benchmark.sweepFailureMessage(
                backend: backend, failure: nil,
                coverage: coverage(unmeasured: [])) == nil)
        }
    }

    @Test("a total refusal reports the refusal, not a list of every cell")
    func totalRefusalTakesPrecedence() throws {
        // Every cell failed, so both signals fire. The operator needs the
        // single cause once, not four copies of it.
        let text = try #require(Benchmark.sweepFailureMessage(
            backend: .paged, failure: failure(),
            coverage: coverage(unmeasured: [
                (1, "refused"), (2, "refused"), (4, "refused"), (8, "refused"),
            ])))
        #expect(text.contains("produced no decode cells"))
        #expect(text.contains("kernel_preflight: ineligible head dim"))
        #expect(!text.contains("B=8"))
    }
}
