import Foundation
import ProviderCore

public struct ArrivalInvarianceBenchmarkReport: Codable, Sendable {
    public struct Row: Codable, Sendable {
        public let row: Int
        public let promptTokens: Int
        public let tokenArrivalTimesMs: [Double]
        public let scheduledDelayMs: Int
        public let submittedAtMs: Double
        /// Signed distance between the measured submission offset and the
        /// intended one (`submittedAtMs - scheduledDelayMs`); positive means
        /// the request entered the engine later than the topology asked for.
        public let arrivalErrorMs: Double
        public let ttftMs: Double
        public let decodeTokensPerSecond: Double
        public let generatedTokens: Int
        public let completedAtMs: Double
        public let tokenChecksum: String
    }

    public struct Sample: Codable, Sendable {
        public let iteration: Int
        public let rows: [Row]
        public let aggregateDecodeTokensPerSecond: Double
        public let endToEndTokensPerSecond: Double
        public let makespanMs: Double
        /// Worst absolute arrival error across this sample's rows.
        public let maxArrivalErrorMs: Double
        /// Attempts discarded before this one because their arrivals missed
        /// the tolerance. Non-zero means the host was scheduling badly.
        public let discardedAttempts: Int
    }

    public struct Pattern: Codable, Sendable {
        public let name: String
        public let arrivalDelaysMs: [Int]
        public let samples: [Sample]
        public let medianTTFTMs: Double
        public let medianPerRequestDecodeTokensPerSecond: Double
        public let medianAggregateDecodeTokensPerSecond: Double
        public let medianMakespanMs: Double
        public let outputsStableAcrossIterations: Bool
        public let outputsMatchBurst: Bool
        /// Per-row median of the *measured* submission offsets, directly
        /// comparable to `arrivalDelaysMs`.
        public let measuredArrivalOffsetsMs: [Double]
        public let maxArrivalErrorMs: Double
        public let arrivalWithinTolerance: Bool
    }

    /// 2 adds the measured delivered-topology evidence (per-row
    ///   `submittedAtMs`/`arrivalErrorMs`, the tolerance, discarded attempts).
    /// 3 adds the required `kvBackend` block: the selection this run was
    ///   launched with and the backend its engine actually built. Without it
    ///   the phase's numbers cannot be attributed to an arm, and `.auto`
    ///   resolves CONTIGUOUS.
    /// 4 adds required effective config-projected Gemma settings.
    /// 5 adds per-row prompt lengths and raw host token-arrival times.
    public static let currentSchemaVersion = 5

    public let schemaVersion: Int
    public let modelID: String
    public let modelPath: String
    public let promptTokensPerRequest: Int
    /// Exact per-row lengths; legacy scalar is only the fallback.
    public let promptLengthsPerRequest: [Int]
    public let decodeTokensPerRequest: Int
    public let iterations: Int
    /// Config-projected Gemma settings this subprocess actually benchmarked.
    public let gemmaOptimizations: BenchmarkGemmaOptimizations
    /// Bound enforced on every measured row's `arrivalErrorMs`. Samples that
    /// exceed it are re-run, and the benchmark fails rather than reporting
    /// numbers produced by a topology it did not actually deliver.
    public let arrivalToleranceMs: Double
    public let arrivalMaxAttemptsPerSample: Int
    /// Selection versus the backend the ONE engine every pattern is measured
    /// on actually resolved to. One engine per run (deliberately: every
    /// arrival topology must see the same warm engine), so `resolved` carries
    /// exactly one descriptor on any run that got that far.
    public let kvBackend: BenchmarkKVBackend
    public let patterns: [Pattern]

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

