// Copyright © 2026 Eigen Labs.
//
// `darkbloom benchmark --parity` exit status.
//
// The gate's whole value to CI is its status byte, so the mapping from report
// to status is pinned here at the CLI seam — the same place
// `BenchmarkSweepExitTests` pins `--sweep`'s. The rule that matters: a run
// that evaluated nothing must not look like a green run to `set -e`.

import Foundation
import ProviderBenchmark
import Testing

@testable import darkbloom

@Suite("benchmark parity exit status")
struct BenchmarkParityExitTests {

    private func report(
        _ verdicts: [(BackendParityReport.CriterionID, BackendParityReport.Verdict)]
    ) -> BackendParityReport {
        BackendParityReport(
            modelID: "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
            modelPath: "/tmp/gemma",
            arms: [
                BackendParityReport.Arm(
                    selection: "contiguous", resolvedBackend: "contiguous",
                    fallbackReason: nil, constructionFailure: nil),
                BackendParityReport.Arm(
                    selection: "paged", resolvedBackend: "paged",
                    fallbackReason: nil, constructionFailure: nil),
            ],
            criteria: verdicts.map { id, verdict in
                BackendParityReport.Criterion(
                    id: id, title: id.rawValue, verdict: verdict, detail: "fixture")
            })
    }

    @Test("every criterion passing exits 0")
    func passExitsZero() {
        let status = Benchmark.parityExitStatus(report([
            (.tokenExactness, .pass),
            (.prefixReuse, .pass),
        ]))
        #expect(status == 0)
    }

    @Test("a failing criterion exits 1")
    func failureExitsOne() {
        let status = Benchmark.parityExitStatus(report([
            (.tokenExactness, .pass),
            (.mtpTokenExactness, .fail),
        ]))
        #expect(status == 1)
    }

    @Test("an all-skipped run exits 2, not 0")
    func allSkippedExitsTwo() {
        let status = Benchmark.parityExitStatus(report([
            (.tokenExactness, .unavailable),
            (.mtpTokenExactness, .unavailable),
            (.packedPrefill, .unavailable),
            (.visionSpans, .unavailable),
            (.prefixReuse, .unavailable),
        ]))
        #expect(status == 2)
        #expect(status != 0)
    }

    @Test("a partial pass still exits 0 — skips do not veto measured passes")
    func partialPassExitsZero() {
        let status = Benchmark.parityExitStatus(report([
            (.tokenExactness, .pass),
            (.packedPrefill, .unavailable),
        ]))
        #expect(status == 0)
    }

    @Test("failure and total-absence are distinguishable statuses")
    func failureAndAbsenceDiffer() {
        let failed = Benchmark.parityExitStatus(report([(.tokenExactness, .fail)]))
        let absent = Benchmark.parityExitStatus(report([(.tokenExactness, .unavailable)]))
        #expect(failed != absent)
        #expect(failed != 0)
        #expect(absent != 0)
    }
}
