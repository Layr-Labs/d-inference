import Foundation
import MLXLMCommon

extension ThroughputSweepReport {
    /// Arrival times use the shared batch epoch, in milliseconds. These are
    /// consumer-side event observations, not GPU completion timestamps. Raw
    /// token IDs allow comparison across equivalent baseline/candidate runs.
    public struct DecodeRowTiming: Codable, Sendable {
        public let row: Int
        public let submittedAtMs: Double
        public let tokenIDs: [Int]
        public let tokenArrivalMs: [Double]
        public let finishedAtMs: Double
        public let finishReason: String
    }

    public struct DecodeTiming: Codable, Sendable {
        public let clock: String
        public let decodePromptTokens: Int?
        public let rows: [DecodeRowTiming]
        public let peakMemoryBytes: Int
        public let endToEndTokensPerSecond: Double
        /// Common interval (latest first token, earliest last token]. All
        /// rows have emitted their first token and none has emitted its last
        /// before the interval ends. This excludes staggered prefill and the
        /// batch drain. It does not prove scheduler batch occupancy or remove
        /// host-delivery jitter; GPU/step traces supply that attribution.
        public let overlapStartMs: Double?
        public let overlapEndMs: Double?
        public let overlapDurationMs: Double?
        public let overlapDecodedTokens: Int?
        public let overlapDecodedTokensPerRow: [Int]?
        public let overlapAggregateTokensPerSecond: Double?
        public let overlapUnavailableReason: String?
        /// Small intersections can yield unstable rates even when nonempty.
        /// Preserve the raw rate, but require this support flag for a baseline.
        public let overlapMinimumTokensPerRow: Int
        public let overlapMeetsMinimumSupport: Bool

        static func make(
            rows: [DecodeRowTiming], peakMemoryBytes: Int, decodePromptTokens: Int? = nil
        ) -> Self {
            let submitted = rows.map(\.submittedAtMs).min() ?? 0
            let finished = rows.map(\.finishedAtMs).max() ?? submitted
            let totalTokens = rows.reduce(0) { $0 + $1.tokenIDs.count }
            let endToEnd = finished > submitted
                ? Double(totalTokens) * 1000 / (finished - submitted) : 0
            let firsts = rows.compactMap { $0.tokenArrivalMs.first }
            let lasts = rows.compactMap { $0.tokenArrivalMs.last }
            let start = firsts.max() ?? 0
            let end = lasts.min() ?? 0
            let valid = !rows.isEmpty && firsts.count == rows.count
                && lasts.count == rows.count && end > start
            // Drop exactly ONE prefill token per row, even if the first
            // delta contains multiple tokens. Count (start,end] so the token
            // at the opening boundary does not get charged zero time.
            let counts = valid ? rows.map { row in
                row.tokenArrivalMs.dropFirst().filter { $0 > start && $0 <= end }.count
            } : []
            let total = counts.reduce(0, +)
            let measured = valid && counts.allSatisfy { $0 > 0 }
            return Self(
                clock: "ContinuousClock host event arrival; shared batch epoch",
                decodePromptTokens: decodePromptTokens,
                rows: rows,
                peakMemoryBytes: peakMemoryBytes,
                endToEndTokensPerSecond: endToEnd,
                overlapStartMs: measured ? start : nil,
                overlapEndMs: measured ? end : nil,
                overlapDurationMs: measured ? end - start : nil,
                overlapDecodedTokens: measured ? total : nil,
                overlapDecodedTokensPerRow: measured ? counts : nil,
                overlapAggregateTokensPerSecond: measured
                    ? Double(total) * 1000 / (end - start) : nil,
                overlapUnavailableReason: measured ? nil
                    : "No positive shared decode interval with a decoded token from every row; increase decode tokens.",
                overlapMinimumTokensPerRow: 32,
                overlapMeetsMinimumSupport: measured && counts.allSatisfy { $0 >= 32 })
        }
    }
}

extension ThroughputSweep {
    /// A fixed-budget sweep must fail closed on both typed terminals and
    /// silent truncation. A .length finish may mean the context limit, so it
    /// cannot replace the exact emitted-token check.
    static func decodeRowFailure(
        expectedTokens: Int, tokenCount: Int, finishReason: CBv2FinishReason?
    ) -> String? {
        guard finishReason == .length else {
            return "unexpected finish: \(String(describing: finishReason))"
        }
        guard tokenCount == expectedTokens else {
            return "expected \(expectedTokens) generated tokens, received \(tokenCount)"
        }
        return nil
    }
}
