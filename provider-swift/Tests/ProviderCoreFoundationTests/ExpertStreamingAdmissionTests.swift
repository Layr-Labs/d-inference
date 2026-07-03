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

    // MARK: - autoExpertCacheGb (cap-derived, never physical RAM)

    /// The invariant the whole budget hangs off: resident + cache +
    /// activations + KV target ≤ hard cap. On a 64 GB box the cap is
    /// min(0.9 × 64, 64 − 2) = 57.6.
    func testAutoExpertCacheGbBudgetsUnderTheHardCap() {
        // 57.6 cap − 19.2 resident − 3 activations − 8 KV target = 27.4.
        let cache = ExpertStreamingAdmission.autoExpertCacheGb(
            hardCapGb: 57.6, residentWeightsGb: 19.2, activationReserveGb: 3)
        XCTAssertEqual(cache, 27.4, accuracy: 0.01)
        XCTAssertLessThanOrEqual(
            19.2 + cache + 3 + ExpertStreamingAdmission.autoCacheKVTargetGb,
            57.6 + 1e-9,  // exact-budget equality, float-addition tolerance only
            "resident + cache + activations + KV must fit under the cap")
    }

    func testAutoExpertCacheGbClampsToZeroOnTightBoxes() {
        // 36 GB box (cap 32.4): 32.4 − 19.2 − 3 − 8 = 2.2 → small cache.
        let smallBox = ExpertStreamingAdmission.autoExpertCacheGb(
            hardCapGb: 32.4, residentWeightsGb: 19.2, activationReserveGb: 3)
        XCTAssertEqual(smallBox, 2.2, accuracy: 0.01)
        // A box where the subtraction goes negative gets ZERO — never a
        // floor that would push resident + cache past the cap (the old
        // 8 GiB floor admitted models the post-load serveability guard
        // then immediately unloaded).
        let tinyBox = ExpertStreamingAdmission.autoExpertCacheGb(
            hardCapGb: 21.6, residentWeightsGb: 19.2, activationReserveGb: 3)
        XCTAssertEqual(tinyBox, 0)
    }

    func testAutoExpertCacheGbCeilingCapsAtSeventyGb() {
        // 128 GB box (cap 115.2), ~19.2 GB resident → naive 85 GB clamps to
        // the 70 GB ceiling so the cache alone can't crowd out KV headroom.
        let cache = ExpertStreamingAdmission.autoExpertCacheGb(
            hardCapGb: 115.2, residentWeightsGb: 19.2, activationReserveGb: 3)
        XCTAssertEqual(cache, ExpertStreamingAdmission.autoCacheCeilingGb)
    }

    // MARK: - expertCacheGb (configured overrides auto, but never past the cap)

    func testExpertCacheGbUsesConfiguredValueWhenPositive() {
        let cache = ExpertStreamingAdmission.expertCacheGb(
            configuredGb: 12, hardCapGb: 115.2, residentWeightsGb: 19.2,
            activationReserveGb: 3)
        XCTAssertEqual(cache, 12)
    }

    func testExpertCacheGbClampsAnOversizedConfiguredValueToTheCap() {
        // Operator asks for 100 GB on a 64 GB box (cap 57.6): clamp to
        // cap − resident − activations − 1 GB minimum KV = 34.4, instead of
        // letting a typo overcommit unified memory.
        let cache = ExpertStreamingAdmission.expertCacheGb(
            configuredGb: 100, hardCapGb: 57.6, residentWeightsGb: 19.2,
            activationReserveGb: 3)
        XCTAssertEqual(cache, 57.6 - 19.2 - 3 - 1, accuracy: 0.01)
    }

    func testExpertCacheGbAutoSizesWhenConfiguredIsZeroOrNegative() {
        let autoSized = ExpertStreamingAdmission.autoExpertCacheGb(
            hardCapGb: 57.6, residentWeightsGb: 19.2, activationReserveGb: 3)
        XCTAssertEqual(
            ExpertStreamingAdmission.expertCacheGb(
                configuredGb: 0, hardCapGb: 57.6, residentWeightsGb: 19.2,
                activationReserveGb: 3),
            autoSized)
        XCTAssertEqual(
            ExpertStreamingAdmission.expertCacheGb(
                configuredGb: -5, hardCapGb: 57.6, residentWeightsGb: 19.2,
                activationReserveGb: 3),
            autoSized)
    }

    // MARK: - estimate (full pipeline) — the 128 GB / 141 GB headline case

    func test141GbCheckpointFitsA128GbBoxViaStreaming() {
        let totalBytes = UInt64(141 * 1024 * 1024 * 1024)
        let switchMlpBytes = UInt64(125 * 1024 * 1024 * 1024)
        // 128 GB box: hard cap = min(0.9 × 128, 126) = 115.2.
        let estimate = ExpertStreamingAdmission.estimate(
            totalBytes: totalBytes, switchMlpBytes: switchMlpBytes,
            hardCapGb: 115.2, activationReserveGb: 3, configuredExpertCacheGb: 0)

        // Resident weights (~19.2 GB) + auto cache must fit under the CAP
        // (115.2), not merely under physical RAM — with room for the
        // activation reserve and the KV target on top.
        XCTAssertEqual(estimate.residentWeightsGb, 19.2, accuracy: 0.01)
        XCTAssertLessThanOrEqual(
            estimate.totalGb + 3 + ExpertStreamingAdmission.autoCacheKVTargetGb,
            115.2 + 0.01,
            "streaming estimate must leave activation + KV room under the 90% cap")
    }

    /// The user-visible fleet boxes: every supported RAM size must produce a
    /// plan where resident + cache + activations + minimum KV fits the cap.
    func testStreamingPlanFitsUnderCapAcrossFleetBoxSizes() {
        let totalBytes = UInt64(141 * 1024 * 1024 * 1024)
        let switchMlpBytes = UInt64(125 * 1024 * 1024 * 1024)
        for physicalGb in [36.0, 48.0, 64.0, 96.0, 128.0] {
            let capGb = min(0.9 * physicalGb, physicalGb - 2)
            let estimate = ExpertStreamingAdmission.estimate(
                totalBytes: totalBytes, switchMlpBytes: switchMlpBytes,
                hardCapGb: capGb, activationReserveGb: 3, configuredExpertCacheGb: 0)
            XCTAssertLessThanOrEqual(
                estimate.totalGb + 3 + 1, capGb + 0.01,
                "\(physicalGb) GB box: resident + cache + activations + min KV must fit cap \(capGb)")
            XCTAssertGreaterThanOrEqual(estimate.expertCacheGb, 0)
        }
    }

    func testNonStreamingEstimateIsUnaffectedByExpertCacheConfig() {
        // Sanity: an `estimate` call with switchMlpBytes == 0 degrades to
        // "resident == ordinary estimate, cache added on top" — this function
        // is only ever invoked from the streaming-aware path, but its math
        // must not silently do something different when nothing streams.
        let totalBytes = UInt64(20 * 1024 * 1024 * 1024)
        let estimate = ExpertStreamingAdmission.estimate(
            totalBytes: totalBytes, switchMlpBytes: 0,
            hardCapGb: 57.6, activationReserveGb: 3, configuredExpertCacheGb: 8)
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
