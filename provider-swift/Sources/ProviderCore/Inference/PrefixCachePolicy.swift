// Copyright © 2026 Eigen Labs.
//
// Production prefix-cache policy. The provider has one local kill switch
// and one production tier: encrypted SSD. In-memory prefix caching remains
// an upstream engine capability, but it is never selected or funded here.

import Foundation
import MLXLMCommon

enum PrefixCachePolicy {

    /// Local cache kill switch. Unset defaults to enabled. Any explicitly
    /// non-affirmative value disables the encrypted SSD cache.
    static let environmentFlag = "DARKBLOOM_PREFIX_CACHE"

    /// Stats-logger cadence override (seconds). Shared semantics with the
    /// legacy checkpoint-tier logger: unset/malformed ⇒ default 120s;
    /// `0` ⇒ disabled; positive ⇒ the cadence.
    static let statsIntervalEnvironmentFlag = "DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS"

    /// Hash-block granularity for the v2 cache. Matches the engine's
    /// `CBv2BlockHasher.defaultBlockSize` (and the legacy block tier's 256).
    static let blockSize = CBv2BlockHasher.defaultBlockSize

    // MARK: - Gate

    /// Encrypted SSD is on by default. Explicit affirmative values keep it
    /// enabled; any other non-empty value disables it.
    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[environmentFlag]?
            .trimmingCharacters(in: .whitespaces).lowercased(),
            !raw.isEmpty
        else {
            return true
        }
        return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
    }

    /// Largest GB value that won't overflow Int when multiplied by 2^30.
    private static var gbToBytesCeiling: Double { Double(Int.max) / 1_073_741_824 }

    // MARK: - SSD disk budget

    /// On-disk budget env override (GB) — the existing operator knob,
    /// now governing the BOX-WIDE SSD-tier budget (adapted from the
    /// retired `BatchScheduler+PrefixCacheSizing` resolver).
    static let diskBudgetEnvironmentFlag = "DARKBLOOM_PREFIX_CACHE_DISK_GB"

    /// Box-wide SSD default: 20 GiB across ALL models (Gaj, 2026-07-07),
    /// clamped to half the volume's free space on a tight disk.
    static let defaultSSDDiskBudgetBytes = 20 * 1_073_741_824

    /// Resolved box-wide SSD disk budget (bytes). A valid positive env
    /// override wins verbatim; otherwise `min(20 GiB, free/2)` — like the
    /// legacy default derivation, re-evaluated per enforcement so the
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
    /// default. Treat that grouping as defensive, and as ACTIVELY WRONG
    /// about config-level `.auto`, which resolves PAGED as of v0.8.0 (see
    /// `EngineV2Factory.prepareProductionBackend`): a caller passing a raw,
    /// unresolved selection would declare a contiguous capability for a
    /// paged slot. Resolve first, always.
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

    // MARK: - Window residency (WS-4.2)

    /// Whether a row of this shape can INSTALL a restored sliding window.
    ///
    /// **Every answer is `false` today, and that is the point of this
    /// function.** WS-4.2 lands the sidecar format, the write path, the read
    /// path and the residency plumbing; it does not land a consumer:
    ///
    ///   * paged would need WS-4.1's `PagedSequenceKV.restoreWindow(_:at:)`,
    ///     which does not exist in this repo — only comments reference it;
    ///   * contiguous would need `CBv2WindowedSequenceKV` adoption of a
    ///     restored ring, which does not exist either;
    ///   * and nothing calls `SSDPrefixCache.stagedWindow(requestID:)`, so
    ///     even a staged window is never handed to the engine.
    ///
    /// Reporting a residency no row can honour is not a cosmetic error: it
    /// collapses the replay bound to zero, so the cache advertises a matched
    /// prefix as free while the engine still performs its full
    /// `windowCount × maxWindow` replay. The bound must therefore stay
    /// conservative until the consumer is real — one edit here, plus its
    /// test, is the flip.

    /// Flips to `true` when `CBv2WindowedSequenceKV` can adopt a restored
    /// ring AND the bridge installs `SSDPrefixCache.stagedWindow(requestID:)`.
    static let contiguousWindowRestoreLanded = false
    /// Flips to `true` when WS-4.1's `PagedSequenceKV.restoreWindow(_:at:)`
    /// (taking a `CBv2PagedWindowSnapshot`) exists AND the bridge installs the
    /// staged window.
    static let pagedWindowRestoreLanded = false

    static func windowRestoreSupported(
        backendSelection: EngineV2KVBackendSelection,
        pagedKilled: Bool = false
    ) -> Bool {
        switch backendSelection {
        case .auto, .contiguous:
            return contiguousWindowRestoreLanded
        case .paged:
            // A KILLED paged slot has degraded to a contiguous row, so it is
            // answered as contiguous.
            return pagedKilled ? contiguousWindowRestoreLanded : pagedWindowRestoreLanded
        }
    }

    /// Whether an adopter's sliding rows are RESTORED from windowed sidecars
    /// or replayed.
    ///
    /// `.restoredFromSidecar` requires all three of:
    ///   * a row that can actually accept a restored window
    ///     (`windowRestoreSupported`) — the fail-closed gate;
    ///   * the operator knob (`SSDPrefixCachePolicy.windowSidecarEnabled`);
    ///   * a layout that tiles into whole-block sidecars
    ///     (`SSDWindowSidecarGeometry.derive` — gpt-oss-20b's 128-token
    ///     window does not, and correctly keeps its 1,536-token bound).
    ///
    /// Note what this does NOT gate: whether sidecars are WRITTEN and READ.
    /// That is the operator knob alone (`SSDPrefixCacheFactory.make`), so the
    /// format, the corpus and both paths stay exercised while the accounting
    /// stays honest.
    static func windowResidency(
        layerKinds: [CBv2LayerKind],
        backendSelection: EngineV2KVBackendSelection,
        pagedKilled: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SSDWindowResidency {
        guard windowRestoreSupported(
            backendSelection: backendSelection, pagedKilled: pagedKilled),
            SSDPrefixCachePolicy.windowSidecarEnabled(environment: environment),
            SSDWindowSidecarGeometry.derive(layerKinds: layerKinds, blockSize: blockSize) != nil
        else { return .replayed }
        return .restoredFromSidecar
    }

    /// Conservative finite-window replay length for the SSD donation/stage
    /// benefit gates; the engine plan remains authoritative per matched
    /// boundary.
    ///
    /// Resolves the backend through `prefixReuseCapability` rather than
    /// hardcoding `.contiguousUnquantized`, so this and its sibling can no
    /// longer describe two different backends for the same slot.
    static func adoptionBoundTokens(
        layerKinds: [CBv2LayerKind],
        backendSelection: EngineV2KVBackendSelection = .auto,
        pagedKilled: Bool = false,
        windowResidency: SSDWindowResidency = .replayed
    ) -> Int {
        adoptionBoundTokens(
            capability: prefixReuseCapability(
                layerKinds: layerKinds,
                backendSelection: backendSelection,
                pagedKilled: pagedKilled),
            layerKinds: layerKinds,
            windowResidency: windowResidency)
    }

    /// Residency-resolved bound for an already-derived capability.
    ///
    /// A restored window means the sliding rows are exact AT the boundary, so
    /// there is nothing to replay and the bound collapses to zero — the whole
    /// point of WS-4.2. It is gated on the geometry existing so that a
    /// residency asserted for a layout that cannot produce whole-block
    /// sidecars still fails closed to replay.
    static func adoptionBoundTokens(
        capability: CBv2PrefixReuseCapability,
        layerKinds: [CBv2LayerKind],
        windowResidency: SSDWindowResidency
    ) -> Int {
        guard windowResidency == .restoredFromSidecar,
            SSDWindowSidecarGeometry.derive(layerKinds: layerKinds, blockSize: blockSize) != nil
        else { return capability.conservativeReplayBoundTokens }
        return 0
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
