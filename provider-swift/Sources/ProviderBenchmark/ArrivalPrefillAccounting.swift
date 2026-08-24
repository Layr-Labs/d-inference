import Foundation

/// Acceptance metric for continuous-batching prefill throughput.
///
/// Matches the shipping scheduler-prefill work accounting (`L - 1` tokens
/// of engine work per row) so B=1 / B=2 / B=4 cells are comparable.
public enum ArrivalPrefillAccounting: Sendable {
    public static let allowedBatchSizes: Set<Int> = [1, 2, 4]

    public static func prefillTokensPerRow(promptTokensPerRequest: Int) -> Int {
        max(0, promptTokensPerRequest - 1)
    }

    /// `max(first_token) - min(submission)`, in seconds.
    public static func prefillMakespanSeconds(
        minSubmissionNs: UInt64,
        maxFirstTokenNs: UInt64
    ) -> Double {
        guard maxFirstTokenNs > minSubmissionNs else { return 0 }
        return Double(maxFirstTokenNs - minSubmissionNs) / 1_000_000_000
    }

    public static func aggregateTokensPerSecond(
        batchSize: Int,
        promptTokensPerRequest: Int,
        prefillMakespanSeconds: Double
    ) -> Double {
        guard batchSize > 0, prefillMakespanSeconds > 0 else { return 0 }
        let tokens = Double(batchSize * prefillTokensPerRow(
            promptTokensPerRequest: promptTokensPerRequest))
        return tokens / prefillMakespanSeconds
    }

    /// Arrival offsets for one named topology at `batchSize` rows.
    public static func delaysMs(batchSize: Int, pattern: String) -> [Int]? {
        switch (batchSize, pattern) {
        case (1, "burst"):
            return [0]
        case (2, "burst"):
            return [0, 0]
        case (2, "stagger-25ms"):
            return [0, 25]
        case (2, "stagger-100ms"):
            return [0, 100]
        case (2, "rolling-250ms"):
            return [0, 250]
        case (4, "burst"):
            return [0, 0, 0, 0]
        case (4, "stagger-25ms"):
            return [0, 25, 50, 75]
        case (4, "stagger-100ms"):
            return [0, 100, 200, 300]
        case (4, "rolling-250ms"):
            return [0, 250, 500, 750]
        default:
            return nil
        }
    }

    /// Stable FNV-1a of the token id stream. Same function the arrival
    /// harness already used; B=1 scheduler-prefill parity uses it too.
    public static func tokenChecksum(_ tokens: [Int]) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for token in tokens {
            var word = UInt64(bitPattern: Int64(token))
            for _ in 0 ..< 8 {
                value ^= word & 0xff
                value &*= 0x100000001b3
                word >>= 8
            }
        }
        return String(format: "%016llx", value)
    }

    public static func patternNames(batchSize: Int) -> [String] {
        switch batchSize {
        case 1:
            return ["burst"]
        case 2, 4:
            return ["burst", "stagger-25ms", "stagger-100ms", "rolling-250ms"]
        default:
            return []
        }
    }
}
