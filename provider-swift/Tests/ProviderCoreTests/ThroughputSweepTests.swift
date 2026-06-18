// Unit tests for the throughput-sweep math + report shape. These are pure
// (no MLX, no model weights, no GPU): they exercise the bandwidth model that
// turns a measured decode tok/s into an implied per-token weight read and the
// JSON report assembly. The actual GPU measurement lives in
// `ProviderCore.ThroughputSweep` and is covered by the live perf tests.

import Foundation
import Testing

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
            notes: ["test"]
        )

        let json = try report.jsonString()
        #expect(json.contains("impliedReadFractionOfWeights"))
        #expect(json.contains("\"regime\""))

        let decoded = try JSONDecoder().decode(
            ThroughputSweepReport.self, from: Data(json.utf8))
        #expect(decoded.modelID == report.modelID)
        #expect(decoded.decode.count == 2)
        #expect(decoded.derived.regime == .dense)
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
