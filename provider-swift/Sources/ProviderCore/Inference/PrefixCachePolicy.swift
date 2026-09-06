// Copyright © 2026 Eigen Labs.
//
// Production prefix-cache policy. Encrypted SSD storage is the default;
// retaining resident KV between requests requires an explicit local opt-in.

import Foundation
import MLXLMCommon

enum PrefixCachePolicy {

    /// Local cache kill switch. Unset defaults to enabled. Any explicitly
    /// non-affirmative value disables resident L1 and encrypted SSD L2.
    static let environmentFlag = "DARKBLOOM_PREFIX_CACHE"

    static let memoryEnvironmentFlag = "DARKBLOOM_PREFIX_CACHE_MEMORY"

    /// Stats-logger cadence override (seconds). Shared semantics with the
    /// legacy checkpoint-tier logger: unset/malformed ⇒ default 120s;
    /// `0` ⇒ disabled; positive ⇒ the cadence.
    static let statsIntervalEnvironmentFlag = "DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS"

    /// Hash-block granularity for the v2 cache. Matches the engine's
    /// `CBv2BlockHasher.defaultBlockSize` (and the legacy block tier's 256).
    static let blockSize = CBv2BlockHasher.defaultBlockSize

    /// Resident L1 indexes one physical page per hash block, matching vLLM's
    /// allocator/index identity. SSD keeps the coarser durable format above.
    static let residentBlockSize = CBv2PagedDefaults.pageSize

    // MARK: - Gate

    /// SSD prefix reuse is on by default. Explicit affirmative values keep it
    /// enabled; any other non-empty value disables all local tiers.
    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environmentEnabled(environment[environmentFlag], defaultValue: true)
    }

    /// One explicit opt-in covers both resident tiers. A byte-budget override
    /// alone cannot keep prompt state in RAM between requests.
    static func isMemoryEnabled(environment: [String: String]) -> Bool {
        isEnabled(environment: environment)
            && environmentEnabled(environment[memoryEnvironmentFlag], defaultValue: false)
    }

    private static func environmentEnabled(_ value: String?, defaultValue: Bool) -> Bool {
        guard let raw = value?.trimmingCharacters(in: .whitespaces).lowercased(),
            !raw.isEmpty else { return defaultValue }
        return ["1", "true", "yes", "on"].contains(raw)
    }

    /// Configuration for the paged backend's copy-free resident L1. The
    /// backend is model-local, so `modelId` scopes unscoped/standalone calls;
    /// authenticated remote requests replace that base scope with their
    /// coordinator-authored `cacheSalt` inside the engine hasher.
    ///
    /// There is deliberately no separate memory budget: indexed zero-ref
    /// pages remain allocator-visible and are invalidated immediately before
    /// reuse, so the paged pool itself is the natural hard bound (vLLM's
    /// unified-pool posture). SSD keeps its independent disk budget.
    static func residentConfig(
        modelId: String,
        promptContractID: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CBv2PagedPrefixCacheConfig? {
        guard isMemoryEnabled(environment: environment),
            let promptContractID = promptContractID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !promptContractID.isEmpty
        else { return nil }
        return CBv2PagedPrefixCacheConfig(
            blockSize: residentBlockSize,
            promptContractID: promptContractID,
            scopeID: modelId)
    }

    /// Attention-only SSD adoption is enabled only for the resolved paged
    /// backend. The original contiguous block path diverged from cold output
    /// on the v0.8.0 Gemma/GPT-OSS model gate, including paged→contiguous fallback.
    /// Refusing construction closes every lookup/staging path and avoids writing
    /// snapshots that this slot cannot safely consume.
    ///
    /// Complete recurrent checkpoints use a separate codec and eligibility gate
    /// in `prepareCompletePrefixCache`; this attention-only rule does not apply
    /// to their native contiguous restoration.
    static func adoptionIsExact(onResolvedBackend kind: EngineV2KVBackendKind) -> Bool {
        switch kind {
        case .paged: return true
        case .contiguous: return false
        }
    }

    /// The capability a slot reports once `adoptionIsExact` has ruled reuse
    /// out for its resolved backend: explicitly UNSUPPORTED, so the
    /// heartbeat's `replay_strategy` reads `none` ("no replay happens on
    /// this slot") rather than `unknown` ("nobody resolved it") or a
    /// strategy name the slot will never execute. The slot's KV backend is
    /// still reported truthfully in `PrefixCacheModelStatus.backend`.
    static func adoptionDisabledCapability(
        layerKinds: [CBv2LayerKind]
    ) -> CBv2PrefixReuseCapability {
        CBv2PrefixReuseCapability.derive(layerKinds: layerKinds, backend: .unknown)
    }

    /// Largest GB value that won't overflow Int when multiplied by 2^30.
    private static var gbToBytesCeiling: Double { Double(Int.max) / 1_073_741_824 }

    // MARK: - SSD disk budget

    /// On-disk budget env override (GB) — the existing operator knob,
    /// now governing the BOX-WIDE SSD-tier budget (adapted from the
    /// retired `BatchScheduler+PrefixCacheSizing` resolver).
    static let diskBudgetEnvironmentFlag = "DARKBLOOM_PREFIX_CACHE_DISK_GB"

    /// Box-wide SSD ceiling across all models, clamped to half the volume's
    /// currently available space.
    static let defaultSSDDiskBudgetBytes = 100 * 1_073_741_824

    /// Resolved box-wide SSD disk budget (bytes). A valid positive env
    /// override wins verbatim; otherwise `min(100 GiB, free/2)`,
    /// re-evaluated per enforcement so the
    /// ceiling shrinks as the volume fills. Unknown free space ⇒ the
    /// fixed default.
    static func ssdDiskBudgetBytes(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        freeBytes: Int?
    ) -> Int {
        let envGB = environment[diskBudgetEnvironmentFlag].flatMap(Double.init)
        if let gb = envGB, gb > 0, gb.isFinite, gb < gbToBytesCeiling {
            return Int(gb * 1_073_741_824)
        }
        guard let free = freeBytes else { return defaultSSDDiskBudgetBytes }
        return max(1, min(defaultSSDDiskBudgetBytes, free / 2))
    }

    /// Best-effort free capacity (bytes) of the volume containing `url`
    /// (moved from the legacy sizing helpers). Prefers Apple's
    /// "important usage" figure, falls back to the raw available capacity.
    static func volumeFreeBytes(at url: URL) -> Int? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        guard let v = try? probe.resourceValues(forKeys: keys) else { return nil }
        if let important = v.volumeAvailableCapacityForImportantUsage, important > 0 {
            return Int(important)
        }
        if let plain = v.volumeAvailableCapacity, plain > 0 { return plain }
        return nil
    }

    // MARK: - Stats cadence

    static let defaultStatsIntervalSecs = 120

    /// Pure stats-interval policy with the retired scheduler's wire-compatible
    /// semantics. Unset / malformed / negative ⇒ default;
    /// `0` ⇒ disabled; a positive value sets the cadence in seconds.
    static func statsIntervalSecs(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let v = environment[statsIntervalEnvironmentFlag] else {
            return defaultStatsIntervalSecs
        }
        guard let n = Int(v), n >= 0 else { return defaultStatsIntervalSecs }
        return n  // 0 ⇒ disabled
    }

    // MARK: - Exact prefix-reuse capability

    /// Construct the engine-owned typed capability for the backend selected
    /// before cache construction. Callers pass a RESOLVED selection derived
    /// from the backend actually built (`EngineV2SlotFactory` maps
    /// `preparedBackend.kind` to `.paged`/`.contiguous`), so `.auto` never
    /// reaches here — it is grouped with `.contiguous` only as a safe
    /// default. Treat that grouping as defensive rather than as a claim
    /// about config-level `.auto`: it happens to agree with the v0.8.1
    /// default and disagreed with v0.8.0's, and a caller passing a raw,
    /// unresolved selection would have declared a contiguous capability
    /// for a paged slot for the whole of that release. Resolve first,
    /// always.
    /// Explicit paged selection remains eligible only for layouts
    /// whose ordinary single-cursor replay is exact; interleaved hybrids fail
    /// cold until a separately-proven paged dual-cursor row exists.
    static func prefixReuseCapability(
        layerKinds: [CBv2LayerKind],
        backendSelection: EngineV2KVBackendSelection,
        pagedKilled: Bool = false
    ) -> CBv2PrefixReuseCapability {
        let backend: CBv2PrefixReuseBackend
        switch backendSelection {
        case .auto, .contiguous:
            backend = .contiguousUnquantized
        case .paged:
            backend = pagedKilled ? .contiguousUnquantized : .pagedFP16
        }
        return CBv2PrefixReuseCapability.derive(
            layerKinds: layerKinds,
            backend: backend)
    }

    /// Conservative finite-window replay length for the SSD donation/stage
    /// benefit gates; the engine plan remains authoritative per matched
    /// boundary.
    ///
    /// Resolves the backend through `prefixReuseCapability` rather than
    /// hardcoding `.contiguousUnquantized`, so this and the capability can no
    /// longer describe two different backends for the same slot.
    ///
    /// WS-4.2 once made this residency-dependent — a boundary whose window
    /// was restored from sidecars had nothing to replay, so the bound
    /// collapsed to zero. No row in this repo can install a restored window
    /// (paged would need `PagedSequenceKV.restoreWindow(_:at:)`, contiguous
    /// a `CBv2WindowedSequenceKV` ring adoption; neither exists), so the
    /// collapsed bound was unreachable and the plumbing carrying it has been
    /// removed. Restoring it means reintroducing a residency input HERE, not
    /// merely landing a consumer: advertising a matched prefix as free while
    /// the engine still performs its full `windowCount × maxWindow` replay is
    /// the failure this conservatism exists to prevent.
    static func adoptionBoundTokens(
        layerKinds: [CBv2LayerKind],
        backendSelection: EngineV2KVBackendSelection = .auto,
        pagedKilled: Bool = false
    ) -> Int {
        prefixReuseCapability(
            layerKinds: layerKinds,
            backendSelection: backendSelection,
            pagedKilled: pagedKilled
        ).conservativeReplayBoundTokens
    }

    /// Real Gemma QAT evidence is noisy/negative at only 1,024 saved tokens
    /// and positive from 1,536 onward; GPT's shorter 1,536-token replay span
    /// remains beneficial at the generic 1,024 floor. The environment may
    /// raise either floor but cannot lower the proved long-hybrid minimum.
    ///
    /// The override keys off the RESOLVED bound, not the capability's raw
    /// one. That evidence was measured against a 25,600-token replay, where
    /// saving 1,024 tokens was within the noise; with the window restored
    /// there is no replay to be noisy about, so the generic floor applies.
    static func minEffectiveTokens(
        capability: CBv2PrefixReuseCapability,
        adoptionBoundTokens: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        let configured = SSDPrefixCachePolicy.minEffectiveTokens(environment: environment)
        let bound = adoptionBoundTokens ?? capability.conservativeReplayBoundTokens
        let longHybridFloor =
            capability.strategy == .frozenFullReplay && bound >= 25_600 ? 1_536 : 0
        return max(configured, longHybridFloor)
    }

}
