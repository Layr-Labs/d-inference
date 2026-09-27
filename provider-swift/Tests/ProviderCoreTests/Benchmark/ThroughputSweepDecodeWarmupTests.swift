import Testing
import MLXLMCommon
@testable import ProviderBenchmark

@Suite("throughput sweep: warmup validation")
struct ThroughputSweepDecodeWarmupTests {
    @Test("all requested shapes finish warming before measurements may start")
    func completeWarmup() async throws {
        var warmed: [Int] = []
        try await ThroughputSweep.warmDecodeShapes(batchSizes: [1, 2, 4]) { batchSize in
            warmed.append(batchSize)
            return (nil, nil)
        }
        #expect(warmed == [1, 2, 4])
    }

    @Test("construction refusal stops the sweep before measurements")
    func constructionFailure() async {
        var attempted: [Int] = []
        var reachedMeasurements = false
        do {
            try await ThroughputSweep.warmDecodeShapes(batchSizes: [1, 2, 4]) { batchSize in
                attempted.append(batchSize)
                return (batchSize == 2 ? "insufficient KV capacity" : nil, nil)
            }
            reachedMeasurements = true
        } catch let error as ThroughputSweep.DecodeWarmupFailure {
            #expect(error.batchSize == 2)
            #expect(error.reason.contains("insufficient KV capacity"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(attempted == [1, 2])
        #expect(!reachedMeasurements)
    }

    @Test("submission, terminal, and token-count failures stop before measurements",
          arguments: ["submission", "error", "cancelled", "missing", "truncated"])
    func rowFailure(kind: String) async {
        let terminal: CBv2FinishReason?
        switch kind {
        case "error": terminal = .error("GPU fault")
        case "cancelled": terminal = .cancelled
        case "missing": terminal = nil
        default: terminal = .length
        }
        let rowFailure = kind == "submission" ? "capacityExhausted"
            : ThroughputSweep.decodeRowFailure(
                expectedTokens: 5, tokenCount: kind == "truncated" ? 4 : 5,
                finishReason: terminal)
        let cell = ThroughputSweep.aggregateRows([
            .init(produced: 4, elapsed: .seconds(1)),
            .init(produced: 4, elapsed: .seconds(1), submitFailure: rowFailure),
        ])
        #expect(cell.submitFailure != nil)

        var attempted: [Int] = []
        var reachedMeasurements = false
        do {
            try await ThroughputSweep.warmDecodeShapes(batchSizes: [1, 2, 4]) { batchSize in
                attempted.append(batchSize)
                return (nil, batchSize == 2 ? cell.submitFailure : nil)
            }
            reachedMeasurements = true
        } catch let error as ThroughputSweep.DecodeWarmupFailure {
            #expect(error.batchSize == 2)
            #expect(error.reason == "row failed: \(cell.submitFailure!)")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(attempted == [1, 2])
        #expect(!reachedMeasurements)
    }
}
