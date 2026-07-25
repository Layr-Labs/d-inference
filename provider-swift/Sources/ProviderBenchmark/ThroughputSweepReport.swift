import Foundation

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
    public static let currentSchemaVersion = 2

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

        public init(
            batchSize: Int,
            decodeTokensPerSequence: Int,
            aggregateTokensPerSecond: Double,
            perSequenceTokensPerSecond: Double,
            elapsedMs: Double
        ) {
            self.batchSize = batchSize
            self.decodeTokensPerSequence = decodeTokensPerSequence
            self.aggregateTokensPerSecond = aggregateTokensPerSecond
            self.perSequenceTokensPerSecond = perSequenceTokensPerSecond
            self.elapsedMs = elapsedMs
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

    public let schemaVersion: Int
    public let modelID: String
    public let modelPath: String
    public let hardware: Hardware
    public let prefill: [PrefillSample]
    public let decode: [DecodeSample]
    public let derived: Derived
    public let notes: [String]
    /// Non-nil only when no decode cell could be constructed. Omitted from
    /// the JSON entirely on a healthy run, so successful reports keep their
    /// existing shape.
    public let decodeConstructionFailure: DecodeConstructionFailure?

    public init(
        schemaVersion: Int = ThroughputSweepReport.currentSchemaVersion,
        modelID: String,
        modelPath: String,
        hardware: Hardware,
        prefill: [PrefillSample],
        decode: [DecodeSample],
        derived: Derived,
        notes: [String],
        decodeConstructionFailure: DecodeConstructionFailure? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.modelID = modelID
        self.modelPath = modelPath
        self.hardware = hardware
        self.prefill = prefill
        self.decode = decode
        self.derived = derived
        self.notes = notes
        self.decodeConstructionFailure = decodeConstructionFailure
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
