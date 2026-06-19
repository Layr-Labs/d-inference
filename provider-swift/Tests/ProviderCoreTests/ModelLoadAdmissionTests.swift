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

// OOM-safety #1: the free figure is clamped to what the OS actually reports
// available, NOT just total − MLX.active − MLX.cache. MLX may be holding almost
// nothing while another process (or the OS) has eaten most of RAM.
@Test func freeIsClampedToRealSystemAvailable() {
    // 64 GB box, MLX holding nothing → MLX view says ~60 GB free, but the OS
    // reports only 10 GB actually available. We must take the OS figure.
    let free = ModelLoadAdmission.freeForLoadGb(
        totalBytes: 64 * gib,
        systemAvailableBytes: 10 * gib,
        gpuActiveBytes: 0, gpuCacheBytes: 0,
        reserveBytes: 4 * gib)
    // realFree = min(64, 10) = 10; minus 4 reserve → 6
    #expect(abs(free - 6.0) < 0.001)
}

@Test func systemClampBlocksLoadThatMlxViewWouldAllow() {
    // gpt-oss (13.5 GB) on a 64 GB box looks fine to the MLX view, but if the OS
    // only has 12 GB free right now the load must be rejected, not OOM'd.
    let ok = ModelLoadAdmission.canLoad(
        weightsGb: 13.5, headroomGb: 2.0,
        totalBytes: 64 * gib,
        systemAvailableBytes: 12 * gib,
        gpuActiveBytes: 0, gpuCacheBytes: 0,
        reserveBytes: 4 * gib)
    // realFree = min(64,12)=12; minus 4 → 8 usable; required 15.5 → reject
    #expect(!ok, "must reject when the OS, not MLX, is the binding constraint")
}

// OOM-safety #2: KV already promised to in-flight requests is subtracted, so a
// concurrent cold-load can't claim memory a mid-decode request is counting on.
@Test func outstandingReservationsReduceFree() {
    // 32 GB box, 4 GB reserve, 6 GB of KV promised to in-flight requests.
    let free = ModelLoadAdmission.freeForLoadGb(
        totalBytes: 32 * gib,
        gpuActiveBytes: 0, gpuCacheBytes: 0,
        reserveBytes: 4 * gib,
        outstandingReservationBytes: 6 * gib)
    // 32 - 4 reserve - 6 reserved → 22
    #expect(abs(free - 22.0) < 0.001)
}

@Test func outstandingReservationsCanBlockASecondLoad() {
    // 24 GB box serving gpt-oss: weights resident (13.5 GB ≈ active) plus 6 GB of
    // promised KV. A second cold-load of another ~13.5 GB model must be rejected.
    let ok = ModelLoadAdmission.canLoad(
        weightsGb: 13.5, headroomGb: 2.0,
        totalBytes: 24 * gib,
        gpuActiveBytes: 13 * gib, gpuCacheBytes: 0,
        reserveBytes: 4 * gib,
        outstandingReservationBytes: 6 * gib)
    // realFree (MLX) = 24-13 = 11; minus 4 reserve minus 6 reserved → 1; need 15.5
    #expect(!ok, "promised KV must block a competing cold-load")
}

// The headline win MUST survive the new clamps: an idle box with low OS usage
// and no reservations still loads gpt-oss on 24 GB.
@Test func idleBoxStillLoadsGptOssWithClamps() {
    let ok = ModelLoadAdmission.canLoad(
        weightsGb: 13.5, headroomGb: 2.0,
        totalBytes: 24 * gib,
        systemAvailableBytes: 21 * gib,   // OS reports plenty free
        gpuActiveBytes: 0, gpuCacheBytes: 0,
        reserveBytes: 4 * gib,
        outstandingReservationBytes: 0)
    #expect(ok, "the core fix must still hold under the OOM-safety clamps")
}

// MARK: - maxLoadableWeightGb (heartbeat free_for_load_gb the coordinator consumes)

// Idle resident models are reclaimable: the provider LRU-evicts them on a cold
// load, so the loadable headroom is computed as if that memory were free.
@Test func maxLoadableWeightReclaimsIdleModels() {
    // 64 GB box, 30 GB idle model resident, sysAvail unknown (.max):
    // reclaimable = min(64, 30) = ... actually min(total, sysAvail+mlxUsed) with
    // sysAvail=.max → min(64, .max)=64; minus 4 reserve minus 4 headroom = 56.
    let w = ModelLoadAdmission.maxLoadableWeightGb(
        totalBytes: 64 * gib, mlxUsedBytes: 30 * gib, reserveBytes: 4 * gib, headroomGb: 4.0)
    #expect(abs(w - 56.0) < 0.001, "idle weights must be reclaimed (got \(w))")
}

// The OS-available clamp still binds — evicting our own MLX adds back only our
// usage, not memory other processes hold.
@Test func maxLoadableWeightClampsToSystemAvailable() {
    // OS reports 10 GB available; evicting our 5 GB MLX → 15 reclaimable.
    // min(64, 10+5)=15; minus 4 reserve minus 4 headroom = 7.
    let w = ModelLoadAdmission.maxLoadableWeightGb(
        totalBytes: 64 * gib, systemAvailableBytes: 10 * gib,
        mlxUsedBytes: 5 * gib, reserveBytes: 4 * gib, headroomGb: 4.0)
    #expect(abs(w - 7.0) < 0.001, "must clamp to OS-available + reclaimable MLX (got \(w))")
}

@Test func maxLoadableWeightFloorsAtZero() {
    let w = ModelLoadAdmission.maxLoadableWeightGb(
        totalBytes: 8 * gib, systemAvailableBytes: 2 * gib,
        mlxUsedBytes: 0, reserveBytes: 4 * gib, headroomGb: 4.0)
    #expect(w == 0, "never negative")
}

// KV already promised to in-flight requests (coordinator or local streams) must
// be held back, exactly as the real load gate does (Codex #390).
@Test func maxLoadableWeightSubtractsOutstandingReservations() {
    // 64 GB idle, 4 GB reserve, 4 GB headroom, 6 GB outstanding KV:
    // reclaimable = 64; minus (4 + 6) committed = 54; minus 4 headroom = 50.
    let w = ModelLoadAdmission.maxLoadableWeightGb(
        totalBytes: 64 * gib, mlxUsedBytes: 0, reserveBytes: 4 * gib,
        headroomGb: 4.0, outstandingReservationBytes: 6 * gib)
    #expect(abs(w - 50.0) < 0.001, "outstanding KV must be subtracted (got \(w))")
}

// THE INVARIANT the coordinator relies on: for an idle box (gpuActive≈0), the
// reported max-loadable-weight equals the largest weight the provider's own
// canLoad gate would accept. So `modelSizeGB <= free_for_load_gb` on the
// coordinator is exactly the provider's load decision — no over/under-admit.
@Test func maxLoadableWeightMirrorsCanLoadWhenIdle() {
    let total: UInt64 = 24 * gib
    let sysAvail: UInt64 = 22 * gib
    let reserve: UInt64 = 4 * gib
    let headroom = 4.0
    let maxW = ModelLoadAdmission.maxLoadableWeightGb(
        totalBytes: total, systemAvailableBytes: sysAvail,
        mlxUsedBytes: 0, reserveBytes: reserve, headroomGb: headroom)
    #expect(ModelLoadAdmission.canLoad(
        weightsGb: maxW, headroomGb: headroom, totalBytes: total,
        systemAvailableBytes: sysAvail, gpuActiveBytes: 0, gpuCacheBytes: 0, reserveBytes: reserve),
        "a model at the reported max must load")
    #expect(!ModelLoadAdmission.canLoad(
        weightsGb: maxW + 0.1, headroomGb: headroom, totalBytes: total,
        systemAvailableBytes: sysAvail, gpuActiveBytes: 0, gpuCacheBytes: 0, reserveBytes: reserve),
        "a model just above the reported max must be rejected")
}

// MARK: - BackendCapacity wire compatibility

@Test func backendCapacityRoundTripsFreeForLoad() throws {
    let cap = BackendCapacity(
        slots: [], gpuMemoryActiveGb: 1, gpuMemoryPeakGb: 2,
        gpuMemoryCacheGb: 0.5, totalMemoryGb: 64, freeForLoadGb: 17.5)
    let data = try JSONEncoder().encode(cap)
    #expect(String(decoding: data, as: UTF8.self).contains("free_for_load_gb"))
    let decoded = try JSONDecoder().decode(BackendCapacity.self, from: data)
    #expect(decoded == cap)
    #expect(abs(decoded.freeForLoadGb - 17.5) < 0.001)
}

@Test func backendCapacityDecodesLegacyWithoutFreeForLoad() throws {
    let legacy = #"{"slots":[],"gpu_memory_active_gb":1,"gpu_memory_peak_gb":2,"gpu_memory_cache_gb":0.5,"total_memory_gb":64}"#
    let decoded = try JSONDecoder().decode(BackendCapacity.self, from: Data(legacy.utf8))
    #expect(decoded.freeForLoadGb == 0, "legacy payload defaults to 0, no throw")
    #expect(abs(decoded.totalMemoryGb - 64) < 0.001)
}
