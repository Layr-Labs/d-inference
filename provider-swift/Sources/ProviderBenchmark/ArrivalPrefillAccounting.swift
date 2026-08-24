import Foundation

/// Acceptance metric for continuous-batching prefill throughput.
///
/// Matches the shipping scheduler-prefill work accounting (`L - 1` tokens
/// of engine work per row) so B=1 / B=2 / B=4 cells are comparable.
public enum ArrivalPrefillAccounting: Sendable {
    public static let allowedBatchSizes: Set<Int> = [1, 2, 4]

    public struct RowTiming: Sendable, Equatable {
        public let submissionNs: UInt64
        public let firstTokenNs: UInt64

        public init(submissionNs: UInt64, firstTokenNs: UInt64) {
            self.submissionNs = submissionNs
            self.firstTokenNs = firstTokenNs
        }
    }

    public struct Metrics: Sendable, Equatable {
        public let makespanSeconds: Double
        public let aggregateTokensPerSecond: Double

        public init(makespanSeconds: Double, aggregateTokensPerSecond: Double) {
            self.makespanSeconds = makespanSeconds
            self.aggregateTokensPerSecond = aggregateTokensPerSecond
        }
    }

    public enum AccountingError: Error, Equatable, CustomStringConvertible {
        case unsupportedBatchSize(Int)
        case invalidPromptTokens(Int)
        case missingRows(expected: Int, actual: Int)
        case firstTokenPrecedesSubmission(row: Int)
        case invalidMakespan
        case invalidAggregate

        public var description: String {
            switch self {
            case .unsupportedBatchSize(let size):
                return "arrival batch size must be 1, 2, or 4 (got \(size))"
            case .invalidPromptTokens(let count):
                return "arrival prompt tokens must be at least 2 (got \(count))"
            case .missingRows(let expected, let actual):
                return "arrival sample produced \(actual) completed rows, expected \(expected)"
            case .firstTokenPrecedesSubmission(let row):
                return "arrival row \(row) recorded its first token before submission"
            case .invalidMakespan:
                return "arrival prefill makespan must be positive and finite"
            case .invalidAggregate:
                return "arrival aggregate prefill throughput must be positive and finite"
            }
        }
    }

    public static func prefillTokensPerRow(promptTokensPerRequest: Int) -> Int {
        guard promptTokensPerRequest > 1 else { return 0 }
        return promptTokensPerRequest - 1
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
        guard batchSize > 0,
              prefillMakespanSeconds.isFinite,
              prefillMakespanSeconds > 0
        else {
            return 0
        }
        // Convert each factor before multiplying. `batchSize * (L - 1)` in
        // `Int` traps on overflow for hostile API inputs before the value can
        // be represented safely as a `Double`.
        let tokens = Double(batchSize)
            * Double(prefillTokensPerRow(promptTokensPerRequest: promptTokensPerRequest))
        let aggregate = tokens / prefillMakespanSeconds
        return aggregate.isFinite ? aggregate : 0
    }

    /// Validates that every requested row completed and derives the exact
    /// acceptance metric from raw monotonic timestamps.
    public static func metrics(
        batchSize: Int,
        promptTokensPerRequest: Int,
        rows: [RowTiming]
    ) throws -> Metrics {
        guard allowedBatchSizes.contains(batchSize) else {
            throw AccountingError.unsupportedBatchSize(batchSize)
        }
        guard promptTokensPerRequest >= 2 else {
            throw AccountingError.invalidPromptTokens(promptTokensPerRequest)
        }
        guard rows.count == batchSize else {
            throw AccountingError.missingRows(expected: batchSize, actual: rows.count)
        }
        for (row, timing) in rows.enumerated() {
            guard timing.firstTokenNs >= timing.submissionNs else {
                throw AccountingError.firstTokenPrecedesSubmission(row: row)
            }
        }
        guard let minSubmission = rows.map(\.submissionNs).min(),
              let maxFirstToken = rows.map(\.firstTokenNs).max()
        else {
            throw AccountingError.missingRows(expected: batchSize, actual: rows.count)
        }
        let makespan = prefillMakespanSeconds(
            minSubmissionNs: minSubmission,
            maxFirstTokenNs: maxFirstToken)
        guard makespan.isFinite, makespan > 0 else {
            throw AccountingError.invalidMakespan
        }
        let aggregate = aggregateTokensPerSecond(
            batchSize: batchSize,
            promptTokensPerRequest: promptTokensPerRequest,
            prefillMakespanSeconds: makespan)
        guard aggregate.isFinite, aggregate > 0 else {
            throw AccountingError.invalidAggregate
        }
        return Metrics(
            makespanSeconds: makespan,
            aggregateTokensPerSecond: aggregate)
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
