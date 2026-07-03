import XCTest
@testable import ProviderCoreFoundation

/// Pure-math coverage for the DeepSeek-V4 MoE expert-streaming memory
/// estimate: `ModelScanner`'s ordinary `estimatedMemoryGb` (full on-disk
/// bytes × 1.2) would refuse to load a ~141 GB checkpoint on a 128 GB box
/// even though streaming makes the real resident footprint only
/// `(totalBytes − switchMlpBytes) × 1.2 + expertCacheBudget`.
final class ExpertStreamingAdmissionTests: XCTestCase {

    private let gib = 1024.0 * 1024.0 * 1024.0

    // MARK: - residentWeightsGb

    func testResidentWeightsGbExcludesSwitchMlpBytes() {
        // 141 GB total, ~125 GB routed experts → ~16 GB non-expert × 1.2.
        let totalBytes = UInt64(141 * 1024 * 1024 * 1024)
        let switchMlpBytes = UInt64(125 * 1024 * 1024 * 1024)
        let resident = ExpertStreamingAdmission.residentWeightsGb(
            totalBytes: totalBytes, switchMlpBytes: switchMlpBytes)
        XCTAssertEqual(resident, 16.0 * 1.2, accuracy: 0.01)
    }

    func testResidentWeightsGbClampsWhenSwitchMlpExceedsTotal() {
        // A mis-measured/over-counted index must never go negative.
        let resident = ExpertStreamingAdmission.residentWeightsGb(
            totalBytes: 10 * UInt64(gib), switchMlpBytes: 20 * UInt64(gib))
        XCTAssertEqual(resident, 0)
    }

    func testResidentWeightsGbWithNoStreamingEqualsTheOrdinaryEstimate() {
        // switchMlpBytes == 0 (nothing streamed) must be byte-identical to
        // ModelScanner's plain `(bytes/GiB) * overheadFactor` estimate — the
        // non-streaming path must never change.
        let totalBytes = UInt64(37 * 1024 * 1024 * 1024)
        let resident = ExpertStreamingAdmission.residentWeightsGb(
            totalBytes: totalBytes, switchMlpBytes: 0)
        let ordinary = (Double(totalBytes) / (1024 * 1024 * 1024)) * 1.2
        XCTAssertEqual(resident, ordinary, accuracy: 0.0001)
    }

    // MARK: - autoExpertCacheGb

    func testAutoExpertCacheGbLeavesTwentyFourGbHeadroom() {
        // 64 GB box, 19.2 GB resident → 64 - 19.2 - 24 = 20.8 GB cache.
        let cache = ExpertStreamingAdmission.autoExpertCacheGb(
            physicalMemoryGb: 64, residentWeightsGb: 19.2)
        XCTAssertEqual(cache, 20.8, accuracy: 0.01)
    }

    func testAutoExpertCacheGbFloorsAtEightGb() {
        // A tight box where the naive subtraction goes negative still gets
        // the 8 GiB floor (not zero, not negative).
        let cache = ExpertStreamingAdmission.autoExpertCacheGb(
            physicalMemoryGb: 32, residentWeightsGb: 19.2)
        XCTAssertEqual(cache, ExpertStreamingAdmission.autoCacheFloorGb)
    }

    func testAutoExpertCacheGbCeilingCapsAtSeventyGb() {
        // 128 GB box, ~19.2 GB resident → naive 84.8 GB clamps to the 70 GB
        // ceiling so the cache alone can't crowd out all KV headroom.
        let cache = ExpertStreamingAdmission.autoExpertCacheGb(
            physicalMemoryGb: 128, residentWeightsGb: 19.2)
        XCTAssertEqual(cache, ExpertStreamingAdmission.autoCacheCeilingGb)
    }

    // MARK: - expertCacheGb (configured overrides auto)

    func testExpertCacheGbUsesConfiguredValueWhenPositive() {
        let cache = ExpertStreamingAdmission.expertCacheGb(
            configuredGb: 12, physicalMemoryGb: 128, residentWeightsGb: 19.2)
        XCTAssertEqual(cache, 12)
    }

    func testExpertCacheGbAutoSizesWhenConfiguredIsZeroOrNegative() {
        let autoSized = ExpertStreamingAdmission.autoExpertCacheGb(
            physicalMemoryGb: 64, residentWeightsGb: 19.2)
        XCTAssertEqual(
            ExpertStreamingAdmission.expertCacheGb(
                configuredGb: 0, physicalMemoryGb: 64, residentWeightsGb: 19.2),
            autoSized)
        XCTAssertEqual(
            ExpertStreamingAdmission.expertCacheGb(
                configuredGb: -5, physicalMemoryGb: 64, residentWeightsGb: 19.2),
            autoSized)
    }

    // MARK: - estimate (full pipeline) — the 128 GB / 141 GB headline case

    func test141GbCheckpointFitsA128GbBoxViaStreaming() {
        let totalBytes = UInt64(141 * 1024 * 1024 * 1024)
        let switchMlpBytes = UInt64(125 * 1024 * 1024 * 1024)
        let estimate = ExpertStreamingAdmission.estimate(
            totalBytes: totalBytes, switchMlpBytes: switchMlpBytes,
            physicalMemoryGb: 128, configuredExpertCacheGb: 0)

        // Resident weights alone (~19.2 GB) plus even the max 70 GB cache
        // leaves well under the 128 GB box, unlike the naive 141*1.2=169.2 GB
        // full-footprint estimate that would refuse to load at all.
        XCTAssertLessThan(estimate.totalGb, 128)
        XCTAssertEqual(estimate.residentWeightsGb, 19.2, accuracy: 0.01)
    }

    func testNonStreamingEstimateIsUnaffectedByExpertCacheConfig() {
        // Sanity: an `estimate` call with switchMlpBytes == 0 degrades to
        // "resident == ordinary estimate, cache added on top" — this function
        // is only ever invoked from the streaming-aware path, but its math
        // must not silently do something different when nothing streams.
        let totalBytes = UInt64(20 * 1024 * 1024 * 1024)
        let estimate = ExpertStreamingAdmission.estimate(
            totalBytes: totalBytes, switchMlpBytes: 0,
            physicalMemoryGb: 64, configuredExpertCacheGb: 8)
        XCTAssertEqual(estimate.residentWeightsGb, 24.0, accuracy: 0.01)  // 20 * 1.2
        XCTAssertEqual(estimate.expertCacheGb, 8)
        XCTAssertEqual(estimate.totalGb, 32.0, accuracy: 0.01)
    }

    // MARK: - isSwitchMlpKey (mirrors DeepseekV4Model.shouldStreamWeight)

    func testIsSwitchMlpKeyMatchesRoutedExpertTensors() {
        XCTAssertTrue(ExpertStreamingAdmission.isSwitchMlpKey(
            "model.layers.3.ffn.switch_mlp.gate_proj.weight"))
        XCTAssertTrue(ExpertStreamingAdmission.isSwitchMlpKey(
            "layers.3.ffn.switch_mlp.up_proj.weight"))
    }

    func testIsSwitchMlpKeyExcludesMTPLayersEvenWithMatchingSuffix() {
        // MTP layers always keep the resident path — mirrors the mlx-swift-lm
        // `sanitize`/`shouldStreamWeight` exclusion exactly.
        XCTAssertFalse(ExpertStreamingAdmission.isSwitchMlpKey(
            "mtp.layers.0.ffn.switch_mlp.gate_proj.weight"))
    }

    func testIsSwitchMlpKeyExcludesUnrelatedTensors() {
        XCTAssertFalse(ExpertStreamingAdmission.isSwitchMlpKey(
            "model.layers.3.self_attn.q_proj.weight"))
        XCTAssertFalse(ExpertStreamingAdmission.isSwitchMlpKey("model.embed_tokens.weight"))
    }
}
