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
// The `auto` half matters just as much: `auto` promised nothing about the
// backend, so a run that could not build one is an ordinary bad run and
// must keep its existing exit status. Widening the failure to `auto` would
// start failing scripts that are green today.

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
}
