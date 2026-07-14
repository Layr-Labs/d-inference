import Foundation

public struct MTPBenchmarkStreamTiming: Equatable, Sendable {
    public let timeToFirstTokenMs: Double
    public let interTokenLatencyMs: Double
    public let decodeTokensPerSecond: Double
    public let lastTokenLatencyMs: Double

    public init(
        timeToFirstTokenMs: Double,
        interTokenLatencyMs: Double,
        decodeTokensPerSecond: Double,
        lastTokenLatencyMs: Double
    ) {
        self.timeToFirstTokenMs = timeToFirstTokenMs
        self.interTokenLatencyMs = interTokenLatencyMs
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.lastTokenLatencyMs = lastTokenLatencyMs
    }
}

public enum MTPBenchmarkTiming {
    /// Pure nanosecond-based timing used by both the live runner and
    /// deterministic unit tests. Throughput uses N-1 decode intervals and the
    /// last token timestamp, never terminal-event delivery.
    public static func stream(
        submittedAtNanoseconds: UInt64,
        tokenTimestampsNanoseconds: [UInt64]
    ) throws -> MTPBenchmarkStreamTiming {
        guard let first = tokenTimestampsNanoseconds.first,
              let last = tokenTimestampsNanoseconds.last
        else { throw MTPBenchmarkError.invalidTokenTimeline("no token timestamps") }
        guard first >= submittedAtNanoseconds else {
            throw MTPBenchmarkError.invalidTokenTimeline("first token predates submission")
        }
        for (previous, next) in zip(
            tokenTimestampsNanoseconds, tokenTimestampsNanoseconds.dropFirst())
        where next < previous {
            throw MTPBenchmarkError.invalidTokenTimeline(
                "token timestamps are not monotonic: \(previous) then \(next)")
        }

        let decodeIntervals = tokenTimestampsNanoseconds.count - 1
        let decodeNanoseconds = last - first
        let itlMs = decodeIntervals > 0
            ? milliseconds(decodeNanoseconds) / Double(decodeIntervals)
            : 0
        let decodeTPS = decodeIntervals > 0 && decodeNanoseconds > 0
            ? Double(decodeIntervals) / (Double(decodeNanoseconds) / 1_000_000_000)
            : 0
        return MTPBenchmarkStreamTiming(
            timeToFirstTokenMs: milliseconds(first - submittedAtNanoseconds),
            interTokenLatencyMs: itlMs,
            decodeTokensPerSecond: decodeTPS,
            lastTokenLatencyMs: milliseconds(last - submittedAtNanoseconds))
    }

    /// Aggregate batch throughput shares one interval across every stream:
    /// earliest first token through latest last token. The numerator is the
    /// sum of each stream's N-1 decode intervals.
    public static func aggregateDecodeTokensPerSecond(
        tokenTimestampsNanoseconds streams: [[UInt64]]
    ) throws -> Double {
        guard !streams.isEmpty, streams.allSatisfy({ !$0.isEmpty }) else {
            throw MTPBenchmarkError.invalidTokenTimeline(
                "aggregate timing requires at least one token per stream")
        }
        for timestamps in streams {
            _ = try stream(
                submittedAtNanoseconds: timestamps[0],
                tokenTimestampsNanoseconds: timestamps)
        }
        let first = streams.compactMap(\.first).min()!
        let last = streams.compactMap(\.last).max()!
        let intervals = streams.reduce(0) { $0 + max(0, $1.count - 1) }
        let elapsed = last - first
        guard intervals > 0, elapsed > 0 else { return 0 }
        return Double(intervals) / (Double(elapsed) / 1_000_000_000)
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }
}
