import Foundation
import Testing
@testable import ProviderCore

private let gib: UInt64 = 1024 * 1024 * 1024

@Test func freeForLoadHasNoSafetyDiscount() {
    // 32 GB box, 4 GB reserve, nothing loaded → 28 GB free (NOT 28*0.7).
    let free = ModelLoadAdmission.freeForLoadGb(
        totalBytes: 32 * gib, gpuActiveBytes: 0, gpuCacheBytes: 0, reserveBytes: 4 * gib)
    #expect(abs(free - 28.0) < 0.001)
}

@Test func freeForLoadSubtractsResidentAndReserve() {
    // 64 GB, 30 GB already resident (active), 2 GB cache, 4 GB reserve → 28 GB.
    let free = ModelLoadAdmission.freeForLoadGb(
        totalBytes: 64 * gib, gpuActiveBytes: 30 * gib, gpuCacheBytes: 2 * gib, reserveBytes: 4 * gib)
    #expect(abs(free - 28.0) < 0.001)
}

@Test func requiredToLoadIsWeightsPlusHeadroom() {
    #expect(abs(ModelLoadAdmission.requiredToLoadGb(weightsGb: 13.5, headroomGb: 2.0) - 15.5) < 0.001)
    // Negative inputs are floored at 0.
    #expect(ModelLoadAdmission.requiredToLoadGb(weightsGb: -5, headroomGb: -1) == 0)
}

// The headline fix: gpt-oss-20b (~13.5 GB weights) MUST load on a 24 GB box.
// Old gate: weights×2.0=27 vs free×0.7=(24-4)*0.7=14 → 27>14 → REJECTED.
// New gate: 13.5+2=15.5 vs free=20 → ADMITTED.
@Test func gptOssLoadsOn24GB() {
    let ok = ModelLoadAdmission.canLoad(
        weightsGb: 13.5, headroomGb: 2.0,
        totalBytes: 24 * gib, gpuActiveBytes: 0, gpuCacheBytes: 0, reserveBytes: 4 * gib)
    #expect(ok, "gpt-oss must load on a 24 GB box now")

    // And the OLD doubly-discounted gate would have rejected it — prove the gap.
    let oldFreeUsable = ((24.0 - 4.0)) * 0.7        // 14.0
    let oldRequired = 13.5 * 2.0                      // 27.0
    #expect(oldRequired > oldFreeUsable, "regression guard: old gate rejected this")
}

// gemma-4-26b (~31 GB weights, 8-bit) genuinely does NOT fit a 32 GB box
// (weights + OS already ≈ the whole box) — must be rejected, not OOM'd.
@Test func gemma8bitRejectedOn32GB() {
    let ok = ModelLoadAdmission.canLoad(
        weightsGb: 31.3, headroomGb: 2.0,
        totalBytes: 32 * gib, gpuActiveBytes: 0, gpuCacheBytes: 0, reserveBytes: 4 * gib)
    #expect(!ok, "gemma-8bit can't fit 32 GB; must be rejected")
}

// …but the 64 GB tier (18 machines in the fleet) MUST now serve gemma.
// Old gate needed free ≥ 31.3*2/0.7 ≈ 89 GB → rejected every box < ~96 GB.
@Test func gemmaLoadsOn64GB() {
    let ok = ModelLoadAdmission.canLoad(
        weightsGb: 31.3, headroomGb: 2.0,
        totalBytes: 64 * gib, gpuActiveBytes: 0, gpuCacheBytes: 0, reserveBytes: 4 * gib)
    #expect(ok, "gemma must load on a 64 GB box now (was rejected before)")
}

@Test func cannotLoadWhenAnotherModelIsResident() {
    // 64 GB box already holding gemma (31 GB resident) can't also cold-load it
    // again / a second big model — eviction path handles that, gate says no room.
    let ok = ModelLoadAdmission.canLoad(
        weightsGb: 31.3, headroomGb: 2.0,
        totalBytes: 64 * gib, gpuActiveBytes: 31 * gib, gpuCacheBytes: 0, reserveBytes: 4 * gib)
    // free = 64-31-4 = 29; required = 33.3 → false
    #expect(!ok)
}
