// Unit tests for the throughput-sweep math + report shape. These are pure
// (no MLX, no model weights, no GPU): they exercise the bandwidth model that
// turns a measured decode tok/s into an implied per-token weight read and the
// JSON report assembly. The actual GPU measurement lives in
// `ProviderCore.ThroughputSweep` and is covered by the live perf tests.

import Foundation
import Testing

@testable import ProviderBenchmark
@testable import ProviderCore

@Suite("throughput sweep: bandwidth model")
struct DecodeBandwidthModelTests {

    @Test("forward model: active params -> decode tok/s")
    func forwardModel() {
        // 4B active, 4-bit (0.5625 B/param), 400 GB/s @ 80% => 2.25 GB/token.
        let readGB = DecodeBandwidthModel.readGBPerToken(
            activeParams: 4e9, bytesPerParam: DecodeBandwidthModel.fourBitBytesPerParam)
        #expect(abs(readGB - 2.25) < 1e-9)

        let tps = DecodeBandwidthModel.expectedDecodeTokensPerSecond(
            activeParams: 4e9, bytesPerParam: DecodeBandwidthModel.fourBitBytesPerParam,
            bandwidthGBps: 400, efficiency: 0.8)
        // 400 * 0.8 / 2.25 = 142.22 tok/s
        #expect(abs(tps - (320.0 / 2.25)) < 1e-6)
    }

    @Test("inverse model round-trips the forward model")
    func inverseRoundTrip() {
        let bw = 400.0, eff = 0.8, bpp = DecodeBandwidthModel.fourBitBytesPerParam
        let tps = DecodeBandwidthModel.expectedDecodeTokensPerSecond(
            activeParams: 4e9, bytesPerParam: bpp, bandwidthGBps: bw, efficiency: eff)

        let impliedRead = DecodeBandwidthModel.impliedReadGBPerToken(
            decodeTokensPerSecond: tps, bandwidthGBps: bw, efficiency: eff)
        #expect(abs(impliedRead - 2.25) < 1e-6)

        let impliedParams = DecodeBandwidthModel.impliedActiveParams(
            decodeTokensPerSecond: tps, bandwidthGBps: bw, bytesPerParam: bpp, efficiency: eff)
        #expect(abs(impliedParams - 4e9) < 1.0)  // within 1 param of 4B
    }

    @Test("zero / negative inputs are safe")
    func degenerateInputs() {
        #expect(DecodeBandwidthModel.readGBPerToken(activeParams: 0, bytesPerParam: 0.5) == 0)
        #expect(DecodeBandwidthModel.expectedDecodeTokensPerSecond(
            activeParams: 0, bandwidthGBps: 400) == 0)
        #expect(DecodeBandwidthModel.impliedReadGBPerToken(
            decodeTokensPerSecond: 0, bandwidthGBps: 400) == 0)
        #expect(DecodeBandwidthModel.impliedActiveParams(
            decodeTokensPerSecond: 0, bandwidthGBps: 400) == 0)
    }

    @Test("bytesPerParam maps quant bit widths")
    func bytesPerParamMapping() {
        #expect(DecodeBandwidthModel.bytesPerParam(forQuantBits: 4) == DecodeBandwidthModel.fourBitBytesPerParam)
        #expect(DecodeBandwidthModel.bytesPerParam(forQuantBits: 8) == DecodeBandwidthModel.eightBitBytesPerParam)
        #expect(DecodeBandwidthModel.bytesPerParam(forQuantBits: 16) == DecodeBandwidthModel.halfBytesPerParam)
        // Unknown / nil defaults to the production 4-bit case.
        #expect(DecodeBandwidthModel.bytesPerParam(forQuantBits: nil) == DecodeBandwidthModel.fourBitBytesPerParam)
        #expect(DecodeBandwidthModel.bytesPerParam(forQuantBits: 3) == DecodeBandwidthModel.fourBitBytesPerParam)
    }

    @Test("regime classification: dense vs sparse vs intermediate")
    func regimeClassification() {
        // ~26B 4-bit ≈ 14.6 GB total.
        let total = 14.6
        // Dense-like: read almost the whole model each token.
        #expect(DecodeBandwidthModel.classifyRegime(impliedReadGB: 14.0, totalWeightGB: total) == .dense)
        // Sparse: read a small slice (≈ 4B active).
        #expect(DecodeBandwidthModel.classifyRegime(impliedReadGB: 2.25, totalWeightGB: total) == .sparse)
        // In between.
        #expect(DecodeBandwidthModel.classifyRegime(impliedReadGB: 7.0, totalWeightGB: total) == .intermediate)
        // Degenerate.
        #expect(DecodeBandwidthModel.classifyRegime(impliedReadGB: 0, totalWeightGB: total) == .intermediate)
        #expect(DecodeBandwidthModel.classifyRegime(impliedReadGB: 5, totalWeightGB: 0) == .intermediate)
    }

    @Test("batch-scaling linearity: dense ~1.0, sparse <1.0")
    func batchScalingLinearity() {
        let dense = DecodeBandwidthModel.batchScalingLinearity(aggregateByBatch: [
            (1, 100), (2, 200), (4, 400),
        ])
        #expect(dense != nil)
        #expect(abs(dense! - 1.0) < 1e-9)

        let sparse = DecodeBandwidthModel.batchScalingLinearity(aggregateByBatch: [
            (1, 100), (2, 150), (4, 220),
        ])
        #expect(sparse != nil)
        // (1.5/2 + 2.2/4) / 2 = (0.75 + 0.55)/2 = 0.65
        #expect(abs(sparse! - 0.65) < 1e-9)

        // No B=1 anchor -> nil.
        #expect(DecodeBandwidthModel.batchScalingLinearity(aggregateByBatch: [(2, 100)]) == nil)
        // Only B=1 -> nil.
        #expect(DecodeBandwidthModel.batchScalingLinearity(aggregateByBatch: [(1, 100)]) == nil)
    }
}

@Suite("throughput sweep: row aggregation")
struct ThroughputSweepRowAggregationTests {

    @Test("decode sweep ignores EOS to preserve a fixed token budget")
    func fixedDecodeBudget() {
        #expect(ThroughputSweep.fixedBudgetStopTokens.isEmpty)
    }

    @Test("clean rows aggregate tokens and the slowest row's elapsed")
    func cleanRowsAggregate() {
        let cell = ThroughputSweep.aggregateRows([
            .init(produced: 10, elapsed: .seconds(1)),
            .init(produced: 12, elapsed: .seconds(3)),
            .init(produced: 11, elapsed: .seconds(2)),
        ])
        #expect(cell.totalTokens == 33)
        #expect(cell.maxElapsed == .seconds(3))
        #expect(cell.submitFailure == nil)
    }

    @Test("ANY row whose submit threw poisons the cell: it is unmeasured, not a zero sample")
    func submitFailurePoisonsCell() {
        // The regression this pins: a B=8 cell where one row's
        // `engine.submit` threw (admission/runtime capacity) used to come
        // back as a MEASURED cell with a deflated token count, and an
        // explicit-backend sweep exited 0 over a corrupted curve. The
        // failure must surface so the caller records the cell in
        // `decodeCoverage.unmeasured` and the release gate rejects the run.
        let cell = ThroughputSweep.aggregateRows([
            .init(produced: 10, elapsed: .seconds(1)),
            .init(produced: 0, elapsed: .zero, submitFailure: "capacityExhausted"),
            .init(produced: 12, elapsed: .seconds(2)),
        ])
        #expect(cell.submitFailure == "capacityExhausted")
    }

    @Test("the first failure is kept when several rows throw")
    func firstFailureKept() {
        let cell = ThroughputSweep.aggregateRows([
            .init(produced: 0, elapsed: .zero, submitFailure: "first"),
            .init(produced: 0, elapsed: .zero, submitFailure: "second"),
        ])
        #expect(cell.submitFailure == "first")
        #expect(cell.totalTokens == 0)
    }
}

@Suite("throughput sweep: report assembly + JSON")
struct ThroughputSweepReportTests {

    private func decodeSamples(b1Aggregate: Double) -> [ThroughputSweepReport.DecodeSample] {
        [
            ThroughputSweepReport.DecodeSample(
                batchSize: 1, decodeTokensPerSequence: 64,
                aggregateTokensPerSecond: b1Aggregate,
                perSequenceTokensPerSecond: b1Aggregate, elapsedMs: 1000),
            ThroughputSweepReport.DecodeSample(
                batchSize: 2, decodeTokensPerSequence: 64,
                aggregateTokensPerSecond: b1Aggregate * 1.8,
                perSequenceTokensPerSecond: b1Aggregate * 0.9, elapsedMs: 1000),
        ]
    }

    @Test("makeDerived flags a dense-decoding MoE")
    func derivedDense() {
        // 26B params, 4-bit (=> 14.625 GB), decoding at only 21 tok/s @ B=1 on
        // a 400 GB/s machine ⇒ implied read ≈ 15.2 GB/token ≈ the whole model.
        let derived = ThroughputSweepReport.makeDerived(
            decode: decodeSamples(b1Aggregate: 21),
            totalParams: 26_000_000_000,
            weightBytes: Int(26_000_000_000.0 * DecodeBandwidthModel.fourBitBytesPerParam),
            quantBits: 4,
            bandwidthGBps: 400,
            efficiency: 0.8
        )
        #expect(derived.regime == .dense)
        #expect(derived.impliedReadFractionOfWeights > 0.6)
        #expect(abs(derived.bytesPerParamEffective - DecodeBandwidthModel.fourBitBytesPerParam) < 1e-6)
        // implied active params should be near the full model, not ~4B.
        #expect(derived.impliedActiveParamsAtB1 > 20e9)
    }

    @Test("makeDerived flags a genuinely sparse MoE")
    func derivedSparse() {
        // Same model decoding at ~142 tok/s ⇒ implied read ≈ 2.25 GB ≈ 4B active.
        let derived = ThroughputSweepReport.makeDerived(
            decode: decodeSamples(b1Aggregate: 142.2),
            totalParams: 26_000_000_000,
            weightBytes: Int(26_000_000_000.0 * DecodeBandwidthModel.fourBitBytesPerParam),
            quantBits: 4,
            bandwidthGBps: 400,
            efficiency: 0.8
        )
        #expect(derived.regime == .sparse)
        #expect(derived.impliedReadFractionOfWeights < 0.3)
        #expect(derived.impliedActiveParamsAtB1 < 6e9)
    }

    @Test("report JSON round-trips and carries the headline fields")
    func jsonRoundTrip() throws {
        let derived = ThroughputSweepReport.makeDerived(
            decode: decodeSamples(b1Aggregate: 21),
            totalParams: 26_000_000_000,
            weightBytes: Int(26_000_000_000.0 * DecodeBandwidthModel.fourBitBytesPerParam),
            quantBits: 4, bandwidthGBps: 400)
        let report = ThroughputSweepReport(
            modelID: "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
            modelPath: "/models/gemma",
            hardware: .init(chipName: "Apple M4 Max", memoryGb: 128, gpuCores: 40, memoryBandwidthGbs: 546),
            prefill: [.init(promptTokens: 128, prefillTokensPerSecond: 900, elapsedMs: 142)],
            decode: decodeSamples(b1Aggregate: 21),
            derived: derived,
            notes: ["test"],
            gemmaOptimizations: .init(settings: GemmaOptimizationSettings())
        )

        let json = try report.jsonString()
        #expect(json.contains("impliedReadFractionOfWeights"))
        #expect(json.contains("\"regime\""))
        // A healthy run keeps its old shape: the OPEN-9 failure block is
        // omitted from the JSON entirely, not emitted as null.
        #expect(!json.contains("decodeConstructionFailure"))

        let decoded = try JSONDecoder().decode(
            ThroughputSweepReport.self, from: Data(json.utf8))
        #expect(decoded.modelID == report.modelID)
        #expect(decoded.decode.count == 2)
        #expect(decoded.derived.regime == .dense)
        #expect(decoded.gemmaOptimizations.prefillLayer18)
        #expect(decoded.gemmaOptimizations.weightedR1)
        #expect(decoded.gemmaOptimizations.environment == [
            GemmaOptimizationEnvironment.prefillLayer18Key: "18",
            GemmaOptimizationEnvironment.weightedUnsortKey: "1",
            GemmaOptimizationEnvironment.safeR1Key: "1",
        ])
        #expect(decoded.schemaVersion == ThroughputSweepReport.currentSchemaVersion)
    }

    @Test("a refused sweep carries the reason, not just an empty curve")
    func constructionFailureRoundTrip() throws {
        // The OPEN-9 case: `--kv-backend paged` on a box that cannot serve
        // paged now refuses per cell, so the sweep measures nothing. The
        // report still ships (an operator needs the artifact) and must say
        // WHY it is empty — `darkbloom benchmark` exits non-zero off this
        // field and quotes the reason.
        let derived = ThroughputSweepReport.makeDerived(
            decode: [], totalParams: 26_000_000_000,
            weightBytes: Int(26_000_000_000.0 * DecodeBandwidthModel.fourBitBytesPerParam),
            quantBits: 4, bandwidthGBps: 400)
        let reason =
            "engine_v2: paged KV backend explicitly requested but unavailable "
            + "— kernel_preflight: PagedKernelPreflightError.ineligible"
        let report = ThroughputSweepReport(
            modelID: "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
            modelPath: "/models/gemma",
            hardware: .init(
                chipName: "Apple M4 Max", memoryGb: 128, gpuCores: 40,
                memoryBandwidthGbs: 546),
            prefill: [],
            decode: [],
            derived: derived,
            notes: ["kv backend: selection=paged, resolved=n/a (no decode cells ran)"],
            gemmaOptimizations: .init(settings: GemmaOptimizationSettings()),
            decodeConstructionFailure: .init(
                kvBackendSelection: "paged", reason: reason)
        )

        let decoded = try JSONDecoder().decode(
            ThroughputSweepReport.self, from: Data(try report.jsonString().utf8))
        let failure = try #require(decoded.decodeConstructionFailure)
        #expect(failure.kvBackendSelection == "paged")
        #expect(failure.reason == reason)
        #expect(decoded.decode.isEmpty)
    }

    @Test("selection and resolved backend are recorded separately, per cell")
    func kvBackendResolutionRoundTrip() throws {
        // The whole point of the block: "I asked for auto" and "I got
        // contiguous at B=8" are different facts. A report that carried only
        // the selection would let a degraded cell be read as a paged
        // measurement, which is what `scripts/gemma_contbatch` gates on.
        let derived = ThroughputSweepReport.makeDerived(
            decode: [], totalParams: 26_000_000_000,
            weightBytes: Int(26_000_000_000.0 * DecodeBandwidthModel.fourBitBytesPerParam),
            quantBits: 4, bandwidthGBps: 400)
        let mixed = [
            ThroughputSweepReport.DecodeSample(
                batchSize: 1, decodeTokensPerSequence: 64,
                aggregateTokensPerSecond: 21, perSequenceTokensPerSecond: 21,
                elapsedMs: 1000, resolvedKVBackend: "paged"),
            ThroughputSweepReport.DecodeSample(
                batchSize: 8, decodeTokensPerSequence: 64,
                aggregateTokensPerSecond: 96, perSequenceTokensPerSecond: 12,
                elapsedMs: 1000,
                resolvedKVBackend: "contiguous (fallback: pool capacity)"),
        ]
        let report = ThroughputSweepReport(
            modelID: "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
            modelPath: "/models/gemma",
            hardware: .init(
                chipName: "Apple M4 Max", memoryGb: 128, gpuCores: 40,
                memoryBandwidthGbs: 546),
            prefill: [],
            decode: mixed,
            derived: derived,
            notes: [],
            gemmaOptimizations: .init(settings: GemmaOptimizationSettings()),
            kvBackend: .init(
                selection: "auto",
                resolved: ["paged", "contiguous (fallback: pool capacity)"])
        )

        let decoded = try JSONDecoder().decode(
            ThroughputSweepReport.self, from: Data(try report.jsonString().utf8))
        #expect(decoded.kvBackend.selection == "auto")
        // Two entries, not one: a mixed-population curve must be visibly
        // mixed rather than collapsed to whichever cell ran first.
        #expect(decoded.kvBackend.resolved.count == 2)
        #expect(decoded.decode.first?.resolvedKVBackend == "paged")
        #expect(decoded.decode.last?.resolvedKVBackend?.hasPrefix("contiguous") == true)
    }

    @Test("a partially measured sweep records WHICH requested cell is missing")
    func decodeCoverageRoundTrip() throws {
        // Each cell builds its own engine sized by its own
        // `maxConcurrentRequests`, which feeds paged physical-capacity
        // planning — so B=1 can resolve paged while B=8 refuses. That run is
        // neither a clean measurement nor a total failure:
        // `decodeConstructionFailure` stays nil because something ran, and
        // before `decodeCoverage` the refused cell was indistinguishable
        // from a slow one (both are a number in the curve).
        let derived = ThroughputSweepReport.makeDerived(
            decode: [], totalParams: 26_000_000_000,
            weightBytes: Int(26_000_000_000.0 * DecodeBandwidthModel.fourBitBytesPerParam),
            quantBits: 4, bandwidthGBps: 400)
        let reason = "engine_v2: paged KV backend explicitly requested but "
            + "unavailable — physical_capacity: pool of 8 sequences exceeds budget"
        let report = ThroughputSweepReport(
            modelID: "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
            modelPath: "/models/gemma",
            hardware: .init(
                chipName: "Apple M4 Max", memoryGb: 128, gpuCores: 40,
                memoryBandwidthGbs: 546),
            prefill: [],
            decode: [
                ThroughputSweepReport.DecodeSample(
                    batchSize: 1, decodeTokensPerSequence: 64,
                    aggregateTokensPerSecond: 21, perSequenceTokensPerSecond: 21,
                    elapsedMs: 1000, resolvedKVBackend: "paged"),
                // The placeholder: zero tok/s, no backend, no measurement.
                ThroughputSweepReport.DecodeSample(
                    batchSize: 8, decodeTokensPerSequence: 64,
                    aggregateTokensPerSecond: 0, perSequenceTokensPerSecond: 0,
                    elapsedMs: 0, resolvedKVBackend: nil),
            ],
            derived: derived,
            notes: [],
            gemmaOptimizations: .init(settings: GemmaOptimizationSettings()),
            kvBackend: .init(selection: "paged", resolved: ["paged"]),
            decodeCoverage: .init(
                requestedBatchSizes: [1, 8],
                unmeasured: [.init(batchSize: 8, reason: reason)])
        )

        let decoded = try JSONDecoder().decode(
            ThroughputSweepReport.self, from: Data(try report.jsonString().utf8))
        // A partial run is NOT a construction failure: that field only ever
        // speaks for a sweep where nothing at all ran.
        #expect(decoded.decodeConstructionFailure == nil)
        #expect(decoded.decodeCoverage.requestedBatchSizes == [1, 8])
        #expect(decoded.decodeCoverage.unmeasured.count == 1)
        #expect(decoded.decodeCoverage.unmeasured.first?.batchSize == 8)
        #expect(decoded.decodeCoverage.unmeasured.first?.reason == reason)
        // The curve still carries the cell, so its length is not silently
        // shorter than the request — the coverage block is what says the
        // zero is an absence.
        #expect(decoded.decode.count == 2)
    }

    @Test("a fully measured sweep reports empty coverage, not an absent block")
    func decodeCoverageAlwaysPresent() throws {
        // `decodeCoverage` is required since schema 4: a gate must be able
        // to tell "no cells were skipped" from "this binary predates the
        // check", and an omitted-when-empty block cannot.
        let derived = ThroughputSweepReport.makeDerived(
            decode: decodeSamples(b1Aggregate: 21), totalParams: 26_000_000_000,
            weightBytes: Int(26_000_000_000.0 * DecodeBandwidthModel.fourBitBytesPerParam),
            quantBits: 4, bandwidthGBps: 400)
        let report = ThroughputSweepReport(
            modelID: "m", modelPath: "/tmp/m",
            hardware: .init(
                chipName: "Apple M4 Max", memoryGb: 128, gpuCores: 40,
                memoryBandwidthGbs: 546),
            prefill: [], decode: decodeSamples(b1Aggregate: 21), derived: derived,
            notes: [],
            gemmaOptimizations: .init(settings: GemmaOptimizationSettings()),
            kvBackend: .init(selection: "paged", resolved: ["paged"]),
            decodeCoverage: .init(requestedBatchSizes: [1, 2], unmeasured: []))
        let json = try report.jsonString()
        #expect(json.contains("decodeCoverage"))

        let decoded = try JSONDecoder().decode(
            ThroughputSweepReport.self, from: Data(json.utf8))
        #expect(decoded.decodeCoverage.unmeasured.isEmpty)
        #expect(decoded.decodeCoverage.requestedBatchSizes == [1, 2])
        #expect(decoded.schemaVersion == ThroughputSweepReport.currentSchemaVersion)
    }
}

@Suite("throughput sweep: token tiling helper")
struct ThroughputSweepTilingTests {

    @Test("tile repeats and rotates to exact length")
    func tileBasics() {
        #expect(ThroughputSweep.tile([1, 2, 3], to: 5) == [1, 2, 3, 1, 2])
        #expect(ThroughputSweep.tile([1, 2, 3], to: 4, offset: 1) == [2, 3, 1, 2])
        #expect(ThroughputSweep.tile([1, 2, 3], to: 2) == [1, 2])
    }

    @Test("tile handles empty base and non-positive length")
    func tileEdges() {
        #expect(ThroughputSweep.tile([], to: 3) == [0, 0, 0])
        #expect(ThroughputSweep.tile([5], to: 0) == [])
        #expect(ThroughputSweep.tile([5, 6], to: 3, offset: 5) == [6, 5, 6])  // offset wraps
    }
}

@Suite("scheduler prefill benchmark helpers")
struct SchedulerPrefillBenchmarkTests {
    @Test("the one-engine harness reports the cbv2 strategy label")
    func strategyLabel() {
        // The legacy fixed-chunk/adaptive strategy machinery died with the
        // legacy engine; CBv2 chunks prefill engine-internally.
        #expect(SchedulerPrefillBenchmark.strategyLabel == "cbv2")
    }
}

// MARK: - --decode-iterations median reduction
//
// `--decode-iterations N` re-runs the whole decode batch curve N times and
// emits every repetition as its own `DecodeSample`. `ThroughputSweep.run` then
// reduces those raw samples with `medianDecodeByBatch` before handing them to
// `ThroughputSweepReport.makeDerived`.
//
// The bug this replaced: a single sample was copied through and *labelled* a
// median, so a wild first observation (cold cache, thermal spike, a stray
// process) became the reported number. These tests pin the reduction so that
// regression cannot come back silently — they are pure arithmetic (no MLX, no
// model, no GPU).

/// Deterministic PRNG so the "input order must not matter" shuffles are
/// reproducible across runs (a flaky permutation would be useless evidence).
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("throughput sweep: decode-iteration median reduction")
struct ThroughputSweepMedianTests {

    // MARK: Fixtures

    /// One decode sample. `perSequence` defaults to the honest
    /// `aggregate / batchSize` the sweep computes.
    private func sample(
        batch: Int,
        aggregate: Double,
        perSequence: Double? = nil,
        elapsedMs: Double = 1000,
        tokensPerSequence: Int = 64
    ) -> ThroughputSweepReport.DecodeSample {
        ThroughputSweepReport.DecodeSample(
            batchSize: batch,
            decodeTokensPerSequence: tokensPerSequence,
            aggregateTokensPerSecond: aggregate,
            perSequenceTokensPerSecond: perSequence ?? (aggregate / Double(batch)),
            elapsedMs: elapsedMs
        )
    }

    /// Emission order of the real sweep: repetition-outer, batch-inner.
    /// `aggregatesByBatch[b]` lists that batch size's per-repetition readings.
    private func curve(_ aggregatesByBatch: [(batch: Int, perRepetition: [Double])])
        -> [ThroughputSweepReport.DecodeSample]
    {
        let reps = aggregatesByBatch.map(\.perRepetition.count).max() ?? 0
        var out: [ThroughputSweepReport.DecodeSample] = []
        for r in 0 ..< reps {
            for entry in aggregatesByBatch where r < entry.perRepetition.count {
                out.append(sample(batch: entry.batch, aggregate: entry.perRepetition[r]))
            }
        }
        return out
    }

    private func aggregate(
        _ samples: [ThroughputSweepReport.DecodeSample], batch: Int
    ) -> Double? {
        samples.first(where: { $0.batchSize == batch })?.aggregateTokensPerSecond
    }

    // MARK: 1. Odd-count median is the true middle, not the first sample

    @Test("odd-count median picks the middle value and ignores a wild first sample")
    func oddCountMedianIgnoresLeadingOutlier() {
        // This is exactly the old bug: the FIRST reading is a wild outlier.
        // A 3-repetition run must report 110, not the 900 it happened to see
        // first.
        #expect(ThroughputSweep.median([900, 100, 110]) == 110)
        // ...and symmetrically for a wild *low* first reading.
        #expect(ThroughputSweep.median([1, 100, 110]) == 100)
        // Middle-of-five, unsorted input.
        #expect(ThroughputSweep.median([4, 1, 3, 2, 5]) == 3)
        // Single value is its own median; N=1 is the default path.
        #expect(ThroughputSweep.median([42.5]) == 42.5)
        // Degenerate input must not trap.
        #expect(ThroughputSweep.median([]) == 0)

        // Restated at the sample level: the reduction must not just take
        // `group.first` (which it does use, but only for the non-numeric
        // `decodeTokensPerSequence` field).
        let reduced = ThroughputSweep.medianDecodeByBatch(
            curve([(batch: 1, perRepetition: [900, 100, 110])]))
        #expect(reduced.count == 1)
        #expect(aggregate(reduced, batch: 1) == 110)
        #expect(aggregate(reduced, batch: 1) != 900)
    }

    // MARK: 2. Even-count median matches Python's statistics.median

    @Test("even-count median averages the two middle values (Python statistics.median)")
    func evenCountMedianAveragesMiddlePair() {
        // CONVENTION: for an even number of samples, `statistics.median` in
        // Python returns the ARITHMETIC MEAN of the two middle values (it is
        // NOT `median_low`/`median_high`). The Python side of this benchmark
        // reduces the same decode samples with `statistics.median`, so the
        // Swift helper must use the same convention or the two reports
        // disagree on identical data.
        //
        // Expected values below were produced by CPython:
        //   statistics.median([10, 20, 30, 40])        -> 25.0
        //   statistics.median([1, 2])                  -> 1.5
        //   statistics.median([1, 2, 3, 4, 5, 6])      -> 3.5
        //   statistics.median([2.5, 7.5])              -> 5.0
        #expect(ThroughputSweep.median([10, 20, 30, 40]) == 25.0)
        #expect(ThroughputSweep.median([1, 2]) == 1.5)
        #expect(ThroughputSweep.median([1, 2, 3, 4, 5, 6]) == 3.5)
        #expect(ThroughputSweep.median([2.5, 7.5]) == 5.0)
        // Unsorted input reduces identically (the helper sorts first).
        #expect(ThroughputSweep.median([40, 10, 30, 20]) == 25.0)

        // Explicitly NOT the low median (20) and NOT the high median (30).
        let m = ThroughputSweep.median([10, 20, 30, 40])
        #expect(m != 20)
        #expect(m != 30)

        // Even repetition counts flow through the sample reduction the same way.
        let reduced = ThroughputSweep.medianDecodeByBatch(
            curve([(batch: 2, perRepetition: [40, 10, 30, 20])]))
        #expect(aggregate(reduced, batch: 2) == 25.0)
    }

    // MARK: 3. Grouping per batch size, independent of input order

    @Test("samples are grouped per batch size and reduced independently")
    func groupsByBatchSizeIndependently() {
        let samples = curve([
            (batch: 1, perRepetition: [900, 100, 110]),  // median 110
            (batch: 2, perRepetition: [200, 220, 210]),  // median 210
            (batch: 4, perRepetition: [400, 352, 300]),  // median 352
        ])
        #expect(samples.count == 9)

        let reduced = ThroughputSweep.medianDecodeByBatch(samples)

        // One row per DISTINCT batch size (not one per repetition), ascending.
        #expect(reduced.count == 3)
        #expect(reduced.map(\.batchSize) == [1, 2, 4])

        // Each batch size is reduced from its OWN group only — no bleed.
        #expect(aggregate(reduced, batch: 1) == 110)
        #expect(aggregate(reduced, batch: 2) == 210)
        #expect(aggregate(reduced, batch: 4) == 352)

        // Non-aggregate numeric fields are reduced by median too.
        #expect(reduced[0].perSequenceTokensPerSecond == 110)  // median of 900/1,100/1,110/1
        #expect(reduced[1].perSequenceTokensPerSecond == 105)  // median of 100,110,105
        #expect(reduced.allSatisfy { $0.decodeTokensPerSequence == 64 })
        #expect(reduced.allSatisfy { $0.elapsedMs == 1000 })
    }

    @Test("input ordering does not change the reduction")
    func reductionIsOrderIndependent() {
        let samples = curve([
            (batch: 1, perRepetition: [900, 100, 110]),
            (batch: 2, perRepetition: [200, 220, 210]),
            (batch: 4, perRepetition: [400, 352, 300]),
        ])
        let expected = ThroughputSweep.medianDecodeByBatch(samples)

        func fingerprint(_ rows: [ThroughputSweepReport.DecodeSample])
            -> [[Double]]
        {
            rows.map {
                [Double($0.batchSize), Double($0.decodeTokensPerSequence),
                 $0.aggregateTokensPerSecond, $0.perSequenceTokensPerSecond, $0.elapsedMs]
            }
        }

        // Reversed emission order.
        #expect(fingerprint(ThroughputSweep.medianDecodeByBatch(samples.reversed()))
            == fingerprint(expected))

        // Batch-outer / repetition-inner (the other plausible loop nesting).
        let batchOuter = [1, 2, 4].flatMap { b in
            samples.filter { $0.batchSize == b }
        }
        #expect(fingerprint(ThroughputSweep.medianDecodeByBatch(batchOuter))
            == fingerprint(expected))

        // Deterministic pseudo-random permutations.
        var rng = SplitMix64(seed: 0xDA4B_1001)
        for _ in 0 ..< 50 {
            let shuffled = samples.shuffled(using: &rng)
            #expect(fingerprint(ThroughputSweep.medianDecodeByBatch(shuffled))
                == fingerprint(expected))
        }
    }

    // MARK: 4. makeDerived consumes the medians, not the first sample

    @Test("derived decode tok/s at B=1 is the median, not the first observation")
    func derivedUsesMedianAtB1() {
        // B=1 readings: 900 (outlier, emitted first), 100, 110 -> median 110.
        let samples = curve([
            (batch: 1, perRepetition: [900, 100, 110]),
            (batch: 2, perRepetition: [220, 220, 220]),
        ])

        let derived = ThroughputSweepReport.makeDerived(
            decode: ThroughputSweep.medianDecodeByBatch(samples),
            totalParams: 26_000_000_000,
            weightBytes: Int(26_000_000_000.0 * DecodeBandwidthModel.fourBitBytesPerParam),
            quantBits: 4,
            bandwidthGBps: 400,
            efficiency: 0.8
        )
        #expect(derived.decodeTokensPerSecondAtB1 == 110)
        #expect(derived.decodeTokensPerSecondAtB1 != 900)

        // The bandwidth inversion therefore hangs off the median as well:
        // 400 * 0.8 / 110 GB/token.
        #expect(abs(derived.impliedReadGBPerTokenAtB1 - (320.0 / 110.0)) < 1e-12)

        // Feeding the RAW samples instead reproduces the old bug: `makeDerived`
        // takes the first B=1 row it finds, i.e. the 900 outlier.
        let rawDerived = ThroughputSweepReport.makeDerived(
            decode: samples,
            totalParams: 26_000_000_000,
            weightBytes: Int(26_000_000_000.0 * DecodeBandwidthModel.fourBitBytesPerParam),
            quantBits: 4,
            bandwidthGBps: 400,
            efficiency: 0.8
        )
        #expect(rawDerived.decodeTokensPerSecondAtB1 == 900)
        #expect(rawDerived.decodeTokensPerSecondAtB1 != derived.decodeTokensPerSecondAtB1)
    }

    @Test("per-batch derived metrics are computed once, not once per repetition")
    func derivedCountsEachBatchSizeOnce() {
        // All B=1 readings identical (110) so the B=1 anchor is the same for
        // both paths — this isolates the "counted N times" effect from the
        // "outlier" effect of the previous test.
        //
        //   B=2 readings 220, 220, 100 -> median 220 -> ratio (220/110)/2 = 1.0
        //   B=4 readings 352, 352, 352 -> median 352 -> ratio (352/110)/4 = 0.8
        //   linearity = mean(1.0, 0.8) = 0.9   (two points, one per batch size)
        let samples = curve([
            (batch: 1, perRepetition: [110, 110, 110]),
            (batch: 2, perRepetition: [220, 220, 100]),
            (batch: 4, perRepetition: [352, 352, 352]),
        ])

        let reduced = ThroughputSweep.medianDecodeByBatch(samples)
        // Two B>1 points reach the linearity average, not six.
        #expect(reduced.count == 3)

        func linearity(_ decode: [ThroughputSweepReport.DecodeSample]) -> Double? {
            ThroughputSweepReport.makeDerived(
                decode: decode,
                totalParams: 26_000_000_000,
                weightBytes: Int(26_000_000_000.0 * DecodeBandwidthModel.fourBitBytesPerParam),
                quantBits: 4, bandwidthGBps: 400, efficiency: 0.8
            ).batchScalingLinearity
        }

        let medianLinearity = try? #require(linearity(reduced))
        #expect(medianLinearity != nil)
        #expect(abs((medianLinearity ?? 0) - 0.9) < 1e-12)

        // Raw samples average SIX ratios (three per batch size), so the low
        // B=2 repetition drags the answer down:
        //   (1.0 + 1.0 + 0.4545… + 0.8 + 0.8 + 0.8) / 6 = 0.80909…
        let rawLinearity = try? #require(linearity(samples))
        #expect(rawLinearity != nil)
        #expect(abs((rawLinearity ?? 0) - 0.8090909090909091) < 1e-12)
        #expect(abs((rawLinearity ?? 0) - (medianLinearity ?? 0)) > 1e-3)
    }

    // MARK: 5. N = 1 (the default) is provably unchanged

    @Test("single-iteration sweeps pass through untouched")
    func singleIterationIsIdentity() throws {
        #expect(ThroughputSweep.defaultDecodeIterations == 1)

        // One sample per batch size — exactly what the default path produces.
        let samples = [
            sample(batch: 1, aggregate: 21, elapsedMs: 1234.5),
            sample(batch: 2, aggregate: 37.8, elapsedMs: 999.25),
            sample(batch: 6, aggregate: 101.4, elapsedMs: 1500),
        ]
        let reduced = ThroughputSweep.medianDecodeByBatch(samples)

        #expect(reduced.count == samples.count)
        for (original, row) in zip(samples, reduced) {
            #expect(row.batchSize == original.batchSize)
            #expect(row.decodeTokensPerSequence == original.decodeTokensPerSequence)
            #expect(row.aggregateTokensPerSecond == original.aggregateTokensPerSecond)
            #expect(row.perSequenceTokensPerSecond == original.perSequenceTokensPerSecond)
            #expect(row.elapsedMs == original.elapsedMs)
        }

        // ...and the whole `derived` block is byte-identical to the pre-median
        // behaviour, so N=1 reports cannot drift.
        func derived(_ decode: [ThroughputSweepReport.DecodeSample]) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(ThroughputSweepReport.makeDerived(
                decode: decode,
                totalParams: 26_000_000_000,
                weightBytes: Int(26_000_000_000.0 * DecodeBandwidthModel.fourBitBytesPerParam),
                quantBits: 4, bandwidthGBps: 400, efficiency: 0.8))
        }
        #expect(try derived(reduced) == (try derived(samples)))
    }

    @Test("empty decode input reduces to an empty curve")
    func emptyInput() {
        #expect(ThroughputSweep.medianDecodeByBatch([]).isEmpty)
    }
}
