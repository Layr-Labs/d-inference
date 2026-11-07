import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

/// Qwen3.8-27B rows at the registered per-rank widths, both ranks in one
/// process (`QwenTensorParallelRowsCheck`): a row's logits and history are
/// the same bytes alone, beside rows of other context lengths that join and
/// leave, across KV segments, while an assistant observes the cohort, and at
/// every verify-window position. GPU-gated (`QWEN_TP_REAL_GEOMETRY_GPU=1`):
/// about 3 GB of random weights for both ranks. Each test runs one half of
/// the check (`QwenTensorParallelRowsCheck.Part`), so CI runs the halves on
/// separate Macs (scripts/cluster-test-plan.py).
@Suite(.serialized)
struct QwenTensorParallelRealGeometryRowsTests {
    static var gpu: Bool { ProcessInfo.processInfo.environment["QWEN_TP_REAL_GEOMETRY_GPU"] == "1" }

    private final class Wire: @unchecked Sendable {
        private let condition = NSCondition()
        private var values: [Int: [Float]] = [:], shapes: [Int: [Int]] = [:]
        private var result: [Float] = []
        private var generation = 0, leaving = 0
        func sum(_ input: MLXArray, rank: Int) -> MLXArray {
            let value = input.asArray(Float.self)
            condition.lock()
            let deadline = Date().addingTimeInterval(300)
            while leaving > 0 { precondition(condition.wait(until: deadline)) }
            let entered = generation
            precondition(values[rank] == nil)
            values[rank] = value; shapes[rank] = input.shape
            if values.count == 2 {
                precondition(shapes[0] == shapes[1])
                result = zip(values[0]!, values[1]!).map(+); leaving = 2; condition.broadcast()
            } else {
                while leaving == 0 && generation == entered { precondition(condition.wait(until: deadline)) }
            }
            let output = result; leaving -= 1
            if leaving == 0 { values = [:]; shapes = [:]; result = []; generation += 1; condition.broadcast() }
            condition.unlock()
            return MLXArray(output, input.shape)
        }
    }
    private final class Rank: QwenTensorParallelReduction, @unchecked Sendable {
        let rank: Int, size = 2, wire: Wire
        init(_ rank: Int, _ wire: Wire) { self.rank = rank; self.wire = wire }
        func allSum(_ value: MLXArray) -> MLXArray { wire.sum(value, rank: rank) }
    }
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var reports: [QwenTensorParallelRowsCheck.Report?] = [nil, nil]
        private(set) var failures: [Error?] = [nil, nil]
        func record(_ rank: Int, _ outcome: Result<QwenTensorParallelRowsCheck.Report, Error>) {
            lock.withLock {
                switch outcome {
                case .success(let report): reports[rank] = report
                case .failure(let error): failures[rank] = error
                }
            }
        }
    }

    /// The runner's comparison (no weights, CPU): a changed digest and a
    /// digest the reference lacks both count; a non-finite row is marked.
    @Test func comparisonCountsChangedAndUnmatchedDigestsAndMarksNonfiniteRows() {
        typealias Trace = QwenTensorParallelRowsCheck.Trace
        typealias Rows = QwenTensorParallelRowsCheck.Rows
        var reference = Trace(), candidate = Trace()
        reference.logits = ["0/0": "a", "0/1": "b"]; reference.history = ["0/1": "h", "0/2": "i"]
        candidate.logits = ["0/0": "a", "0/1": "c", "1/0": "d"]; candidate.history = ["0/2": "i"]
        #expect(candidate.mismatches(reference, label: "x") == ["x logits 0/1", "x logits 1/0"])
        #expect(reference.mismatches(reference, label: "x").isEmpty)
        Device.withDefaultDevice(.cpu) {
            let finite = Rows.digest(MLXArray([Float(1), 2]))
            #expect(finite.count == 64 && !finite.hasPrefix(Rows.nonfinite))
            #expect(Rows.digest(MLXArray([Float(1), .nan])).hasPrefix(Rows.nonfinite))
            #expect(Rows.digest(MLXArray([Float.infinity, 2])).hasPrefix(Rows.nonfinite))
        }
    }

    /// The rows of 100 to 4,090 tokens: P1 on one- and eight-lane hosts, PB8,
    /// PB2, PB4, the observed cohort and the verify windows.
    @Test(.enabled(if: gpu))
    func rowsEqualTheirSoloStepsAndWindowPositionsAtRealWidths() throws {
        try check(.rows)
    }

    /// The rows of 4,000 to 4,600 tokens, whose eight histories span KV
    /// segments, against each row alone.
    @Test(.enabled(if: gpu))
    func rowsAcrossKVSegmentsEqualTheirSoloStepsAtRealWidths() throws {
        try check(.segments)
    }

    private func check(_ part: QwenTensorParallelRowsCheck.Part) throws {
        let configuration = try QwenTensorParallelRowsCheck.configuration(layers: 4)
        let wire = Wire()
        let models = try (0..<2).map { rank in
            try Device.withDefaultDevice(.gpu) {
                try QwenTensorParallelModel.assemble(configurationData: configuration,
                    role: .shard(rank: rank, size: 2), reduction: Rank(rank, wire)) { _, keep in
                    try QwenTensorParallelRowsCheck.tensors(layers: 4, keep)
                }
            }
        }
        Memory.clearCache()
        // Every decode projection takes the batch-invariant kernel: six and two row-parallel
        // partials a Gated DeltaNet layer, five and two an attention layer, and the head.
        let census = QwenTensorParallelBatchSession.censusLine(rank: 0, model: models[0])
        print("qwen27-real-geometry " + census)
        #expect(census.contains(" aqv=24 partial=8 mlx=0 "))

        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 2) { rank in
            Device.withDefaultDevice(.gpu) {
                results.record(rank, Result {
                    try QwenTensorParallelRowsCheck.run(model: models[rank], configuration: configuration, rank: rank,
                        parts: [part])
                })
            }
        }
        for failure in results.failures { if let failure { throw failure } }
        for report in results.reports.compactMap({ $0 }) {
            print("qwen27-real-geometry \(part) rank=\(report.rank) compared=\(report.compared)"
                + " reserved=\(report.reservedBytesAcrossSegments) differing=\(report.differing.count)"
                + " first=\(report.differing.prefix(12))")
            #expect(report.passed)
            // Every digest of the half: each row's prompt logits, its logits
            // and its history after each solo step (8 rows of 12 steps; 8 long
            // rows of 8 steps), 336 a rank for the whole check.
            #expect(report.compared == (part == .rows ? 200 : 136))
        }
        #expect(results.reports.compactMap({ $0 }).count == 2)
    }
}
