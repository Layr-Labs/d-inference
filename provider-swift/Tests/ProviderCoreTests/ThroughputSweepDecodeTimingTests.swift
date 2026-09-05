import Foundation
import Testing
import MLXLMCommon
@testable import ProviderBenchmark

@Suite("throughput sweep: shared decode interval")
struct ThroughputSweepDecodeTimingTests {
    private func row(_ id: Int, _ times: [Double]) -> ThroughputSweepReport.DecodeRowTiming {
        .init(row: id, submittedAtMs: 0, tokenIDs: Array(times.indices),
              tokenArrivalMs: times, finishedAtMs: (times.last ?? 0) + 5,
              finishReason: "length")
    }

    @Test("staggered prefill and batch drain are excluded from common aggregate")
    func commonWindow() {
        let timing = ThroughputSweepReport.DecodeTiming.make(rows: [
            row(0, [10, 20, 30, 40, 50]),
            row(1, [25, 35, 45, 55, 65]),
        ], peakMemoryBytes: 100)
        #expect(timing.overlapStartMs == 25)
        #expect(timing.overlapEndMs == 50)
        #expect(timing.overlapDecodedTokensPerRow == [3, 2])
        #expect(timing.overlapAggregateTokensPerSecond == 200)
        #expect(timing.endToEndTokensPerSecond == 10_000.0 / 70)
    }

    @Test("no overlapping decode is unavailable rather than a fabricated B=2 rate")
    func noOverlap() {
        let timing = ThroughputSweepReport.DecodeTiming.make(rows: [
            row(0, [10, 20]), row(1, [30, 40]),
        ], peakMemoryBytes: 0)
        #expect(timing.overlapAggregateTokensPerSecond == nil)
        #expect(timing.overlapUnavailableReason != nil)
    }

    @Test("B=1 counts decoded tokens only and excludes completion delivery delay")
    func singleRow() {
        let timing = ThroughputSweepReport.DecodeTiming.make(
            rows: [row(0, [10, 20, 30])], peakMemoryBytes: 0)
        #expect(timing.overlapDecodedTokens == 2)
        #expect(timing.overlapAggregateTokensPerSecond == 100)
    }

    @Test("coalesced tokens at the first timestamp do not count zero-time work")
    func coalescedEvent() {
        let timing = ThroughputSweepReport.DecodeTiming.make(
            rows: [row(0, [10, 10, 20, 20, 30])], peakMemoryBytes: 0)
        #expect(timing.overlapDecodedTokens == 3)
        #expect(timing.overlapAggregateTokensPerSecond == 150)
    }

    @Test("runtime failure, truncated length, and absent terminal invalidate a row")
    func failures() {
        #expect(ThroughputSweep.decodeRowFailure(
            expectedTokens: 5, tokenCount: 5, finishReason: .length) == nil)
        #expect(ThroughputSweep.decodeRowFailure(
            expectedTokens: 5, tokenCount: 4, finishReason: .length) != nil)
        #expect(ThroughputSweep.decodeRowFailure(
            expectedTokens: 5, tokenCount: 5, finishReason: .error("GPU fault")) != nil)
        #expect(ThroughputSweep.decodeRowFailure(
            expectedTokens: 5, tokenCount: 5, finishReason: .cancelled) != nil)
        #expect(ThroughputSweep.decodeRowFailure(
            expectedTokens: 5, tokenCount: 5, finishReason: nil) != nil)
    }

    @Test("headline support requires at least 32 overlap tokens from EVERY row")
    func minimumSupport() {
        let sufficient = ThroughputSweepReport.DecodeTiming.make(
            rows: [row(0, (0...32).map(Double.init)), row(1, (0...32).map(Double.init))],
            peakMemoryBytes: 0)
        #expect(sufficient.overlapMinimumTokensPerRow == 32)
        #expect(sufficient.overlapMeetsMinimumSupport)
        let insufficient = ThroughputSweepReport.DecodeTiming.make(
            rows: [row(0, (0...32).map(Double.init)), row(1, (1...32).map(Double.init))],
            peakMemoryBytes: 0)
        #expect(!insufficient.overlapMeetsMinimumSupport)
        #expect(insufficient.overlapAggregateTokensPerSecond != nil)
    }

    @Test("raw timing survives JSON round trip")
    func roundTrip() throws {
        let timing = ThroughputSweepReport.DecodeTiming.make(
            rows: [row(0, [10, 20, 30])], peakMemoryBytes: 42)
        let sample = ThroughputSweepReport.DecodeSample(
            batchSize: 1, decodeTokensPerSequence: 2,
            aggregateTokensPerSecond: 80, perSequenceTokensPerSecond: 80,
            elapsedMs: 25, resolvedKVBackend: "contiguous", decodeTiming: timing)
        let decoded = try JSONDecoder().decode(
            ThroughputSweepReport.DecodeSample.self, from: JSONEncoder().encode(sample))
        #expect(decoded.decodeTiming?.rows.first?.tokenArrivalMs == [10, 20, 30])
        #expect(decoded.decodeTiming?.overlapAggregateTokensPerSecond == 100)
        #expect(decoded.decodeTiming?.peakMemoryBytes == 42)
    }
}
