import Foundation
import ProviderCore

/// Machine-readable result of `darkbloom benchmark --sweep`.
///
/// Holds the raw prefill-throughput and per-batch decode-throughput samples
/// plus a `derived` block that inverts the B=1 decode rate into an implied
/// per-token weight read (see `DecodeBandwidthModel`). Emitted as JSON so it
/// can be diffed across builds / hardware and fed to the analysis in
/// `docs/gemma-decode-bandwidth-analysis.md`.
public struct ThroughputSweepReport: Codable, Sendable {

    /// Bumped when the JSON shape changes so downstream parsers can gate.
    /// 2 adds the optional `decodeConstructionFailure` block.
    /// 3 adds the required `kvBackend` block and the per-cell
    /// `decode[].resolvedKVBackend`.
    /// 4 adds the required `decodeCoverage` block: which cells were ASKED
    /// for versus which ones actually produced a measurement.
    /// 5 adds required effective config-projected Gemma settings.
    public static let currentSchemaVersion = 5

    public struct Hardware: Codable, Sendable {
        public let chipName: String
        public let memoryGb: UInt64
        public let gpuCores: UInt32
        public let memoryBandwidthGbs: UInt32

        public init(chipName: String, memoryGb: UInt64, gpuCores: UInt32, memoryBandwidthGbs: UInt32) {
            self.chipName = chipName
            self.memoryGb = memoryGb
            self.gpuCores = gpuCores
            self.memoryBandwidthGbs = memoryBandwidthGbs
        }
    }

    /// One prefill-throughput data point: feed a `promptTokens`-long prompt
    /// through the model in a single forward pass and time it.
    public struct PrefillSample: Codable, Sendable {
        public let promptTokens: Int
        public let prefillTokensPerSecond: Double
        public let elapsedMs: Double

        public init(promptTokens: Int, prefillTokensPerSecond: Double, elapsedMs: Double) {
            self.promptTokens = promptTokens
            self.prefillTokensPerSecond = prefillTokensPerSecond
            self.elapsedMs = elapsedMs
        }
    }

    /// One decode-throughput data point at a fixed batch size. `aggregate` is
    /// the summed tok/s across all `batchSize` sequences; `perSequence` is
    /// `aggregate / batchSize` (the rate an individual user sees). Both exclude
    /// the first (prefill) token per sequence.
    public struct DecodeSample: Codable, Sendable {
        public let batchSize: Int
        public let decodeTokensPerSequence: Int
        public let aggregateTokensPerSecond: Double
        public let perSequenceTokensPerSecond: Double
        public let elapsedMs: Double
        /// The KV backend the engine for THIS cell actually built with, or
        /// nil when construction failed and the cell measured nothing. Each
        /// batch size builds its own engine sized by its own
        /// `maxConcurrentRequests`, so the outcome can differ per cell —
        /// explicit `.paged` resolving at B=1 and refusing at B=8, or a
        /// degrading selection resolving paged at B=1 and contiguous at
        /// B=8. A single run-wide scalar would hide exactly that.
        public let resolvedKVBackend: String?

        public init(
            batchSize: Int,
            decodeTokensPerSequence: Int,
            aggregateTokensPerSecond: Double,
            perSequenceTokensPerSecond: Double,
            elapsedMs: Double,
            resolvedKVBackend: String? = nil
        ) {
            self.batchSize = batchSize
            self.decodeTokensPerSequence = decodeTokensPerSequence
            self.aggregateTokensPerSecond = aggregateTokensPerSecond
            self.perSequenceTokensPerSecond = perSequenceTokensPerSecond
            self.elapsedMs = elapsedMs
            self.resolvedKVBackend = resolvedKVBackend
        }
    }

    /// Bandwidth interpretation of the B=1 decode point. The headline field is
    /// `impliedReadFractionOfWeights`: ≈ 1.0 means "decoding as if dense".
    public struct Derived: Codable, Sendable {
        public let bandwidthEfficiencyAssumed: Double
        public let bytesPerParamEffective: Double
        public let quantBits: Int?
        public let totalParams: Int
        public let totalWeightGB: Double
        public let decodeTokensPerSecondAtB1: Double
        public let impliedReadGBPerTokenAtB1: Double
        public let impliedActiveParamsAtB1: Double
        public let impliedReadFractionOfWeights: Double
        public let regime: DecodeBandwidthModel.DecodeRegime
        public let batchScalingLinearity: Double?
        /// Reference: a dense model reads its whole footprint each token.
        public let denseReadGBPerTokenReference: Double
        /// Reference: a true ~4B-active MoE at this quantization.
        public let fourBActiveReadGBPerTokenReference: Double
        /// Reference: predicted tok/s if the model decoded as dense (all weights/token).
        public let expectedDenseDecodeTokensPerSecond: Double
        /// Reference: predicted tok/s for a ~4B-active read.
        public let expectedFourBActiveDecodeTokensPerSecond: Double

        public init(
            bandwidthEfficiencyAssumed: Double,
            bytesPerParamEffective: Double,
            quantBits: Int?,
            totalParams: Int,
            totalWeightGB: Double,
            decodeTokensPerSecondAtB1: Double,
            impliedReadGBPerTokenAtB1: Double,
            impliedActiveParamsAtB1: Double,
            impliedReadFractionOfWeights: Double,
            regime: DecodeBandwidthModel.DecodeRegime,
            batchScalingLinearity: Double?,
            denseReadGBPerTokenReference: Double,
            fourBActiveReadGBPerTokenReference: Double,
            expectedDenseDecodeTokensPerSecond: Double,
            expectedFourBActiveDecodeTokensPerSecond: Double
        ) {
            self.bandwidthEfficiencyAssumed = bandwidthEfficiencyAssumed
            self.bytesPerParamEffective = bytesPerParamEffective
            self.quantBits = quantBits
            self.totalParams = totalParams
            self.totalWeightGB = totalWeightGB
            self.decodeTokensPerSecondAtB1 = decodeTokensPerSecondAtB1
            self.impliedReadGBPerTokenAtB1 = impliedReadGBPerTokenAtB1
            self.impliedActiveParamsAtB1 = impliedActiveParamsAtB1
            self.impliedReadFractionOfWeights = impliedReadFractionOfWeights
            self.regime = regime
            self.batchScalingLinearity = batchScalingLinearity
            self.denseReadGBPerTokenReference = denseReadGBPerTokenReference
            self.fourBActiveReadGBPerTokenReference = fourBActiveReadGBPerTokenReference
            self.expectedDenseDecodeTokensPerSecond = expectedDenseDecodeTokensPerSecond
            self.expectedFourBActiveDecodeTokensPerSecond = expectedFourBActiveDecodeTokensPerSecond
        }
    }

    /// Present ONLY when engine construction failed for EVERY decode cell,
    /// so the sweep measured nothing at all. The samples are still emitted
    /// (all zero) and `notes` still records the selection, but a reader —
    /// human or script — needs the CAUSE, not just an empty curve.
    ///
    /// The case this exists for: `--kv-backend paged` on a box where paged
    /// cannot be served. Since OPEN-9 that is a hard refusal rather than a
    /// silent degrade to contiguous, so the run legitimately produces no
    /// numbers, and `darkbloom benchmark` exits non-zero off this field
    /// rather than reporting success with an empty curve.
    public struct DecodeConstructionFailure: Codable, Sendable {
        /// The `--kv-backend` selection the run was launched with.
        public let kvBackendSelection: String
        /// The construction error, verbatim, from the last cell that failed.
        public let reason: String

        public init(kvBackendSelection: String, reason: String) {
            self.kvBackendSelection = kvBackendSelection
            self.reason = reason
        }
    }

    /// What was ASKED FOR versus what was BUILT. Two different facts: the
    /// gap between them is the whole signal a paged rollout is measured on,
    /// and collapsing them into one string makes an honest paged run
    /// indistinguishable from an `.auto` run that degraded to contiguous.
    ///
    /// This exists as structured JSON rather than only as a `notes` line
    /// because the release gates parse it: `scripts/gemma_contbatch` refuses
    /// to diff two reports whose resolved backends differ, and a prose
    /// sentence is not a contract a gate can hold.
    ///
    /// The same record the scheduler-prefill and arrival phases carry — one
    /// type, so a wrapper that pins the sweep's backend pins theirs the same
    /// way.
    public typealias KVBackend = BenchmarkKVBackend

    /// A requested decode cell that produced no measurement because its
    /// engine never built.
    ///
    /// Each cell builds its own engine with its own `maxConcurrentRequests`,
    /// which is an input to paged physical-capacity planning — so B=1 can
    /// resolve paged while B=8 refuses for want of a concurrency-sized pool.
    /// The cell still appears in `decode` as a placeholder zero (dropping it
    /// would silently shorten the curve); this is the record that the zero is
    /// an absence, not an observation.
    public struct UnmeasuredCell: Codable, Sendable {
        /// The batch size the operator asked for and did not get.
        public let batchSize: Int
        /// The construction error for this cell, verbatim.
        public let reason: String

        public init(batchSize: Int, reason: String) {
            self.batchSize = batchSize
            self.reason = reason
        }
    }

    /// Requested-versus-measured decode cells.
    ///
    /// `decodeConstructionFailure` only speaks when NOTHING ran. A sweep
    /// where one cell of four refused is not a total failure and not a clean
    /// run either, and until this block existed that middle case was
    /// unrepresentable: the failed cell's error was discarded and the curve
    /// carried a zero that read like a measurement. An EXPLICIT
    /// `--kv-backend` names a promise about every requested cell, so
    /// `darkbloom benchmark` exits non-zero off `unmeasured` — see
    /// `Benchmark.sweepFailureMessage`.
    public struct DecodeCoverage: Codable, Sendable {
        /// Every batch size the sweep set out to measure, ascending, after
        /// the non-positive entries are dropped.
        public let requestedBatchSizes: [Int]
        /// The requested cells that never built an engine, one entry per
        /// batch size in first-seen order. EMPTY on a fully measured run.
        public let unmeasured: [UnmeasuredCell]

        public init(requestedBatchSizes: [Int], unmeasured: [UnmeasuredCell]) {
            self.requestedBatchSizes = requestedBatchSizes
            self.unmeasured = unmeasured
        }
    }

    public let schemaVersion: Int
    public let modelID: String
    public let modelPath: String
    public let hardware: Hardware
    public let prefill: [PrefillSample]
    public let decode: [DecodeSample]
    public let derived: Derived
    public let notes: [String]
    /// Config-projected Gemma settings this subprocess actually benchmarked.
    public let gemmaOptimizations: BenchmarkGemmaOptimizations
    /// Selection versus resolved backend. Always present since schema 3: a
    /// decode curve whose backend is unknown is not comparable to anything.
    public let kvBackend: KVBackend
    /// Non-nil only when no decode cell could be constructed. Omitted from
    /// the JSON entirely on a healthy run, so successful reports keep their
    /// existing shape.
    public let decodeConstructionFailure: DecodeConstructionFailure?
    /// Requested versus measured decode cells. Always present since schema
    /// 4: a curve that quietly skipped a cell is not the curve that was
    /// asked for, and `decodeConstructionFailure` above only fires when
    /// EVERY cell failed.
    public let decodeCoverage: DecodeCoverage

    public init(
        schemaVersion: Int = ThroughputSweepReport.currentSchemaVersion,
        modelID: String,
        modelPath: String,
        hardware: Hardware,
        prefill: [PrefillSample],
        decode: [DecodeSample],
        derived: Derived,
        notes: [String],
        gemmaOptimizations: BenchmarkGemmaOptimizations,
        kvBackend: KVBackend = KVBackend(selection: "auto", resolved: []),
        decodeConstructionFailure: DecodeConstructionFailure? = nil,
        decodeCoverage: DecodeCoverage = DecodeCoverage(
            requestedBatchSizes: [], unmeasured: [])
    ) {
        self.schemaVersion = schemaVersion
        self.modelID = modelID
        self.modelPath = modelPath
        self.hardware = hardware
        self.prefill = prefill
        self.decode = decode
        self.derived = derived
        self.notes = notes
        self.gemmaOptimizations = gemmaOptimizations
        self.kvBackend = kvBackend
        self.decodeConstructionFailure = decodeConstructionFailure
        self.decodeCoverage = decodeCoverage
    }

    // MARK: - Derived assembly

    /// Build the `Derived` block from raw samples + model/hardware facts. Pure
    /// (no MLX) so it is exercised directly by unit tests.
    public static func makeDerived(
        decode: [DecodeSample],
        totalParams: Int,
        weightBytes: Int,
        quantBits: Int?,
        bandwidthGBps: Double,
        efficiency: Double = DecodeBandwidthModel.defaultBandwidthEfficiency,
        fourBActiveParams: Double = 4e9
    ) -> Derived {
        // Effective bytes/param straight from the loaded weights when we can
        // count them; otherwise fall back to the quant-bit estimate.
        let bytesPerParam: Double = {
            if totalParams > 0, weightBytes > 0 {
                return Double(weightBytes) / Double(totalParams)
            }
            return DecodeBandwidthModel.bytesPerParam(forQuantBits: quantBits)
        }()

        let b1 = decode.first(where: { $0.batchSize == 1 })?.aggregateTokensPerSecond ?? 0
        let totalWeightGB = Double(weightBytes) / 1e9
        let impliedReadGB = DecodeBandwidthModel.impliedReadGBPerToken(
            decodeTokensPerSecond: b1, bandwidthGBps: bandwidthGBps, efficiency: efficiency)
        let impliedActive = DecodeBandwidthModel.impliedActiveParams(
            decodeTokensPerSecond: b1, bandwidthGBps: bandwidthGBps,
            bytesPerParam: bytesPerParam, efficiency: efficiency)
        let frac = totalWeightGB > 0 ? impliedReadGB / totalWeightGB : 0
        let regime = DecodeBandwidthModel.classifyRegime(
            impliedReadGB: impliedReadGB, totalWeightGB: totalWeightGB)
        let linearity = DecodeBandwidthModel.batchScalingLinearity(
            aggregateByBatch: decode.map { ($0.batchSize, $0.aggregateTokensPerSecond) })

        let fourBReadGB = DecodeBandwidthModel.readGBPerToken(
            activeParams: fourBActiveParams, bytesPerParam: bytesPerParam)
        let expectedDense = DecodeBandwidthModel.expectedDecodeTokensPerSecond(
            activeParams: Double(totalParams), bytesPerParam: bytesPerParam,
            bandwidthGBps: bandwidthGBps, efficiency: efficiency)
        let expectedFourB = DecodeBandwidthModel.expectedDecodeTokensPerSecond(
            activeParams: fourBActiveParams, bytesPerParam: bytesPerParam,
            bandwidthGBps: bandwidthGBps, efficiency: efficiency)

        return Derived(
            bandwidthEfficiencyAssumed: efficiency,
            bytesPerParamEffective: bytesPerParam,
            quantBits: quantBits,
            totalParams: totalParams,
            totalWeightGB: totalWeightGB,
            decodeTokensPerSecondAtB1: b1,
            impliedReadGBPerTokenAtB1: impliedReadGB,
            impliedActiveParamsAtB1: impliedActive,
            impliedReadFractionOfWeights: frac,
            regime: regime,
            batchScalingLinearity: linearity,
            denseReadGBPerTokenReference: totalWeightGB,
            fourBActiveReadGBPerTokenReference: fourBReadGB,
            expectedDenseDecodeTokensPerSecond: expectedDense,
            expectedFourBActiveDecodeTokensPerSecond: expectedFourB
        )
    }

    // MARK: - JSON

    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func jsonString(prettyPrinted: Bool = true) throws -> String {
        String(decoding: try jsonData(prettyPrinted: prettyPrinted), as: UTF8.self)
    }
}
