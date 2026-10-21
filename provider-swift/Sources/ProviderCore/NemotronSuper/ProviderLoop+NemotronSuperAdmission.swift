// Copyright © 2026 Eigen Labs.

import Foundation

/// ProviderLoop -- the managed Nemotron Super slot's load gate.
///
/// A Super LOAD claim keeps its own system reserve
/// (`NemotronSuperLoadFit.systemReserveBytes`), not the provider's load
/// reserve, so the ordinary free-memory gate (`availableMemoryGb` against the
/// discovery footprint and the load headroom) cannot predict it: with MLX
/// memory resident it admitted loads every configuration's claim refused.
/// Pre-accept, eviction and startup preload instead compare the claim's own
/// ledger room (`GlobalKVCacheBudget.HeadroomSnapshot.loadClaimRemainingBytes`)
/// with what each configuration requires (`NemotronSuperLoadFit.Claim`).
extension ProviderLoop {
    /// What the managed load's configurations require of the ledger, in the
    /// order it tries them. For the pinned checkpoint: the plan sized for a
    /// lone slot on the loader's machine (re-slicing never grants more, and a
    /// smaller grant needs no more) and each fallback. A fixture loader has
    /// the scanner's estimate alone, and so does a runtime policy the load
    /// refuses by name itself. Empty when no configuration holds the minimum
    /// KV.
    func nemotronSuperLoadRequirements(_ modelInfo: ModelInfo) -> [UInt64] {
        let estimate = Self.pendingLoadReservationBytes(
            estimatedWeightsGb: modelInfo.estimatedMemoryGb, extraWeightBytes: 0)
        guard nemotronSuperSlotLoader.pinned else { return [estimate] }
        let physical = nemotronSuperSlotLoader.physicalBytes
        let grant = Int(clamping: UnifiedMemoryCap.kvBudgetBytes(physicalBytes: physical,
            residentWeightBytes: modelInfo.sizeBytes, activationReserveBytes: resolvedActivationReserveBytes,
            configReserveBytes: Self.memoryReserveBytes(forGiB: loopConfig.config.provider.memoryReserveGB)))
        let plan = nemotronSuperLoadPlan(modelID: modelInfo.id, kvBytesCapacity: grant)
        return (try? NemotronSuperLoadFit.pinnedRequirements(plan: plan, kvBytesCapacity: grant,
                                                              physicalBytes: physical)) ?? [estimate]
    }

    /// What a Super LOAD claim could charge right now.
    func nemotronSuperClaimRoomBytes() -> UInt64 {
        kvBudget.memoryHeadroomSnapshot().loadClaimRemainingBytes(
            systemReserveBytes: NemotronSuperLoadFit.systemReserveBytes(configReserveBytes: kvBudget.configReserveBytes))
    }

    /// `evictUntilAvailable` for the managed Super load. Evicts idle models,
    /// least recently used first, until the claim's room holds the widest
    /// configuration that evicting every idle model could make room for, so
    /// an idle model yields to the planned owner rather than to a narrower
    /// one. Refuses without evicting when not even the narrowest can fit;
    /// `allowEviction: false` only checks.
    func evictUntilNemotronSuperFits(_ modelInfo: ModelInfo, allowEviction: Bool) async throws {
        let requirements = nemotronSuperLoadRequirements(modelInfo)
        guard let narrowest = requirements.last else {
            throw InferenceError.modelLoadFailed(
                "Insufficient memory for '\(modelInfo.id)': no configuration holds the minimum KV on this Mac")
        }
        let unavailable = InferenceError.modelLoadFailed(
            "Insufficient memory for '\(modelInfo.id)': the idle model chosen for eviction became unavailable")
        var declinedEvictions = 0
        while true {
            try Task.checkCancellation()
            if isShuttingDown { throw CancellationError() }
            let room = nemotronSuperClaimRoomBytes()
            let evictable = allowEviction ? evictableModelSlots() : [:]
            let reclaimable = evictable.isEmpty ? 0 : reclaimableMemoryBytes(from: evictable)
            let (reachable, overflow) = room.addingReportingOverflow(reclaimable)
            let target = requirements.first { $0 <= (overflow ? .max : reachable) }
            if let target, room >= target { return }
            // The same bounded recheck as the ordinary gate while macOS
            // returns a retired Super owner's pages. Its pause suspends, so
            // the room and the idle models are sampled again after it.
            if let retirement = nemotronSuperMemoryRetirement, retirement.nextDelay() != nil {
                _ = try await retirement.pauseForRecheck()
                continue
            }
            guard target != nil else {
                if !evictable.isEmpty {
                    throw InferenceError.modelLoadFailed("Insufficient memory (\(Self.gb(room)) GB of LOAD room, "
                        + "need \(Self.gb(narrowest)) GB) even after evicting every idle model "
                        + "(\(Self.gb(reclaimable)) GB reclaimable) — refusing without evicting")
                }
                // Nothing idle to evict: drop the reclaimable pool and resample.
                clearCacheAfterConfirmedNativeOwnership()
                let retried = nemotronSuperClaimRoomBytes()
                if retried >= narrowest { return }
                throw InferenceError.modelLoadFailed("Insufficient memory (\(Self.gb(retried)) GB of LOAD room, "
                    + "need \(Self.gb(narrowest)) GB) " + (allowEviction
                        ? "and all loaded models are actively serving"
                        : "to load without evicting resident models"))
            }
            // The room is short of what idle eviction reaches: an idle model exists.
            guard let victim = evictable.min(by: { $0.value.lastInferenceAt < $1.value.lastInferenceAt })?.key
            else { throw unavailable }
            logger.info("Evicting idle model \(victim) to make room for Nemotron Super")
            if await unloadModel(victim, forEviction: true) { continue }
            // The victim took work while its unload suspended: plan again
            // from the models still idle, a bounded number of times.
            declinedEvictions += 1
            guard declinedEvictions < Self.nemotronSuperDeclinedEvictionLimit else { throw unavailable }
        }
    }

    /// The declined eviction that refuses the Super load. A victim can keep
    /// declining (an autopilot transaction owning residency), so planning
    /// again after a decline is bounded.
    private static let nemotronSuperDeclinedEvictionLimit = 3

    /// `fastAdmissionReject`'s verdict for the managed Super load, on the same
    /// room and requirements as `evictUntilNemotronSuperFits`: certain to fail
    /// only when not even evicting every idle model makes room for its
    /// narrowest configuration, or every slot is busy.
    func nemotronSuperLoadIsCertainToFail(_ modelInfo: ModelInfo) -> Bool {
        let evictable = evictableModelSlots()
        if modelSlots.count >= maxModelSlots, evictable.isEmpty { return true }
        guard let narrowest = nemotronSuperLoadRequirements(modelInfo).last else { return true }
        let room = nemotronSuperClaimRoomBytes()
        if room >= narrowest { return false }
        let mayStillReclaim = nemotronSuperMemoryRetirement?.nextDelay() != nil
        if !evictable.isEmpty {
            let (reachable, overflow) = room.addingReportingOverflow(reclaimableMemoryBytes(from: evictable))
            return !overflow && reachable < narrowest && !mayStillReclaim
        }
        // The same self-heal as the ordinary pre-accept.
        clearCacheAfterConfirmedNativeOwnership()
        return nemotronSuperClaimRoomBytes() < narrowest && !mayStillReclaim
    }

    /// Super's startup preload requirement, in the units of the free figure
    /// the preloader compares it with (`freeGb`): that figure less the room
    /// Super's claim has beyond its narrowest configuration, so a preload
    /// (which never evicts) proceeds exactly when Super's own gate admits it.
    func nemotronSuperPreloadRequiredGb(_ modelInfo: ModelInfo, freeGb: Double) -> Double {
        guard let narrowest = nemotronSuperLoadRequirements(modelInfo).last else { return .infinity }
        return freeGb - (Double(nemotronSuperClaimRoomBytes()) - Double(narrowest)) / 1_073_741_824
    }

    private static func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }
}
