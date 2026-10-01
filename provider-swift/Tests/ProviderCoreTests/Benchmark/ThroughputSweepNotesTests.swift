// Throughput-sweep report text and bookkeeping that need no GPU: the
// operator notes, the resolved-backend and unmeasured-cell records, and the
// config.json reads that pick the load path and the quantization width.

import Foundation
import Testing

@testable import ProviderBenchmark
@testable import ProviderCore

@Suite("throughput sweep: notes and decode bookkeeping")
struct ThroughputSweepNotesTests {
    private let hardware = HardwareInfo(
        machineModel: "fixture", chipName: "fixture", chipFamily: .m4, chipTier: .max,
        memoryGb: 128, memoryAvailableGb: 124,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40, memoryBandwidthGbs: 546)

    private func derived(
        regime: DecodeBandwidthModel.DecodeRegime,
        fraction: Double,
        linearity: Double?
    ) -> ThroughputSweepReport.Derived {
        ThroughputSweepReport.Derived(
            bandwidthEfficiencyAssumed: 0.75, bytesPerParamEffective: 0.5625, quantBits: 4,
            totalParams: 1_000, totalWeightGB: 1, decodeTokensPerSecondAtB1: 10,
            impliedReadGBPerTokenAtB1: fraction, impliedActiveParamsAtB1: 100,
            impliedReadFractionOfWeights: fraction, regime: regime,
            batchScalingLinearity: linearity, denseReadGBPerTokenReference: 1,
            fourBActiveReadGBPerTokenReference: 2, expectedDenseDecodeTokensPerSecond: 3,
            expectedFourBActiveDecodeTokensPerSecond: 4)
    }

    private func temporaryModel(config: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let config {
            try Data(config.utf8).write(to: directory.appendingPathComponent("config.json"))
        }
        return directory
    }

    @Test("dense notes name the selection, unmeasured cells, bandwidth and linearity")
    func denseNotes() {
        let coverage = ThroughputSweepReport.DecodeCoverage(
            requestedBatchSizes: [1, 2],
            unmeasured: [ThroughputSweepReport.UnmeasuredCell(batchSize: 2, reason: "pool too small")])
        let notes = ThroughputSweep.makeNotes(
            hardware: hardware, efficiency: 0.75,
            derived: derived(regime: .dense, fraction: 0.95, linearity: 0.97),
            kvBackend: .paged, resolvedBackends: [], coverage: coverage)
        #expect(notes == [
            "kv backend: selection=paged, resolved=n/a (no decode cells ran) — decode numbers "
                + "describe the RESOLVED backend, not the selection.",
            "UNMEASURED: 1 of 2 requested decode cells built no engine — B=2: pool too small. "
                + "Their samples are placeholder zeros, not measurements.",
            "implied per-token read assumes 75% of 546 GB/s peak bandwidth.",
            "regime=dense: B=1 reads ~95.0% of total weights per token.",
            "DENSE-LIKE: per-token read ≈ full model — expert sparsity is NOT being exploited at decode.",
            "batch-scaling linearity=0.97 (≈1.0 dense-like, <1.0 sparse-like; only meaningful when "
                + "B=1 is bandwidth-bound).",
            "decode tok/s and prefill tok/s are most meaningful in a release build (swift build -c release).",
        ])
    }

    @Test("sparse and intermediate notes join resolved backends and skip absent facts")
    func sparseAndIntermediateNotes() {
        let full = ThroughputSweepReport.DecodeCoverage(requestedBatchSizes: [1], unmeasured: [])
        let sparse = ThroughputSweep.makeNotes(
            hardware: hardware, efficiency: 0.5,
            derived: derived(regime: .sparse, fraction: 0.125, linearity: nil),
            kvBackend: .auto, resolvedBackends: ["paged", "contiguous (fallback: kill switch)"],
            coverage: full)
        #expect(sparse.count == 5)
        #expect(sparse[0].hasPrefix(
            "kv backend: selection=auto, resolved=paged + contiguous (fallback: kill switch) — "))
        #expect(sparse[1] == "implied per-token read assumes 50% of 546 GB/s peak bandwidth.")
        #expect(sparse[2] == "regime=sparse: B=1 reads ~12.5% of total weights per token.")
        #expect(sparse[3] == "SPARSE: per-token read ≪ full model — expert sparsity is being exploited.")
        #expect(!sparse.contains { $0.hasPrefix("batch-scaling") })

        let middle = ThroughputSweep.makeNotes(
            hardware: hardware, efficiency: 0.5,
            derived: derived(regime: .intermediate, fraction: 0.5, linearity: nil),
            kvBackend: .contiguous, resolvedBackends: ["contiguous"], coverage: full)
        #expect(middle.count == 4)
        #expect(middle[2] == "regime=intermediate: B=1 reads ~50.0% of total weights per token.")
        #expect(!middle.contains { $0.hasPrefix("DENSE-LIKE") || $0.hasPrefix("SPARSE") })
    }

    @Test("decode bookkeeping keeps distinct backends and one unmeasured entry per batch size")
    func decodeOutcomeRecords() {
        var outcome = ThroughputSweep.DecodeOutcome()
        #expect(outcome.samples.isEmpty)
        #expect(outcome.constructionFailure == nil)
        #expect(outcome.requestedBatchSizes.isEmpty)

        #expect(!outcome.record(nil))
        #expect(outcome.record("paged"))
        #expect(!outcome.record("paged"))
        #expect(outcome.record("contiguous (fallback: preflight)"))
        #expect(outcome.resolvedBackends == ["paged", "contiguous (fallback: preflight)"])

        #expect(outcome.recordUnmeasured(batchSize: 2, reason: "first"))
        #expect(!outcome.recordUnmeasured(batchSize: 2, reason: "second"))
        #expect(outcome.recordUnmeasured(batchSize: 4, reason: "third"))
        #expect(outcome.unmeasuredCells.map(\.batchSize) == [2, 4])
        #expect(outcome.unmeasuredCells.map(\.reason) == ["first", "third"])
    }

    @Test("a vision_config key selects the VLM load path")
    func visionConfigDetection() throws {
        let vision = try temporaryModel(config: #"{"model_type": "gemma4", "vision_config": {}}"#)
        let text = try temporaryModel(config: #"{"model_type": "gemma4_text"}"#)
        let broken = try temporaryModel(config: "{not json")
        let missing = try temporaryModel(config: nil)
        defer {
            for url in [vision, text, broken, missing] { try? FileManager.default.removeItem(at: url) }
        }
        #expect(ThroughputSweep.readHasVisionConfig(modelDirectory: vision))
        #expect(!ThroughputSweep.readHasVisionConfig(modelDirectory: text))
        #expect(!ThroughputSweep.readHasVisionConfig(modelDirectory: broken))
        #expect(!ThroughputSweep.readHasVisionConfig(modelDirectory: missing))
    }

    @Test("quantization bits come from either quantization key and nothing else")
    func quantizationBits() throws {
        let cases: [(String?, Int?)] = [
            (#"{"quantization": {"bits": 4, "group_size": 64}}"#, 4),
            (#"{"quantization_config": {"bits": 8}}"#, 8),
            (#"{"quantization": {"group_size": 64}, "quantization_config": {"bits": 6}}"#, 6),
            (#"{"quantization": {"bits": "4"}}"#, nil),
            (#"{"model_type": "llama"}"#, nil),
            ("[]", nil),
            (nil, nil),
        ]
        for (config, bits) in cases {
            let directory = try temporaryModel(config: config)
            defer { try? FileManager.default.removeItem(at: directory) }
            #expect(ThroughputSweep.readQuantBits(modelDirectory: directory) == bits)
        }
    }

    @Test("the seed text is a fixed in-vocabulary paragraph")
    func seedText() {
        #expect(ThroughputSweep.seedText.hasPrefix("The quick brown fox"))
        #expect(ThroughputSweep.seedText.hasSuffix("count tokens carefully."))
        #expect(ThroughputSweep.defaultPromptLengths == [128, 512, 2048])
        #expect(ThroughputSweep.defaultBatchSizes == [1, 2, 3, 4, 5, 6])
        #expect(ThroughputSweep.defaultDecodeTokens == 64)
        #expect(ThroughputSweep.defaultDecodePromptTokens == 64)
    }
}
