// Copyright © 2026 Eigen Labs.

import Foundation

extension SSDPrefixCache {
    /// A RAM-index plan is advisory until staging authenticates every file and
    /// reserves the transient bytes. It never grants reuse or emits a receipt.
    struct StageMetadata {
        let blockCount: Int
        let fullTags: [Data]
        let tags16: [Data]
        let runBytes: Int
        let runSizes: [Int]
        let windowTags: [Data]
    }

    enum StagePlan {
        case candidate(StageMetadata)
        case skipped(SSDPrefixCacheStageDisposition)
    }

    func planStaging(
        chainHashes hashes: [Data], cacheScope: String, lookupKeys: SSDLookupKeys
    ) -> StagePlan {
        guard index.count > 0 else { return .skipped(.missAbsent) }
        guard !hashes.isEmpty else { return .skipped(.skippedCost) }
        // Cheap pre-floor: a run can only clear the benefit gate when even
        // a FULL match would (matched − bound ≥ minEffective). Overflow-safe
        // like the donate-path floor: an operator-set
        // `DARKBLOOM_PREFIX_CACHE_SSD_MIN_EFFECTIVE_TOKENS` near Int.max
        // must DISABLE staging (saturated floor never passes), not trap the
        // provider on every request.
        let (preFloor, preFloorOverflow) =
            config.adoptionBoundTokens.addingReportingOverflow(config.minEffectiveTokens)
        guard !preFloorOverflow, hashes.count * config.blockSize >= preFloor
        else { return .skipped(.skippedCost) }

        var fullTags: [Data] = []
        var tags16: [Data] = []
        for hash in hashes {
            let full = lookupKeys.tag(chainHash: hash, cacheSalt: cacheScope)
            fullTags.append(full)
            tags16.append(full.prefix(SSDLookupKeys.truncatedTagLength))
        }
        // WS-4.2: the terminal-four sidecars that would restore the donor's
        // window at each candidate boundary. Probed inside the trim loop so
        // their bytes are inside the stage byte/time caps rather than added
        // on top of a run those caps already saturated.
        let windowGeometry = config.windowSidecar

        // Longest contiguous run, trimmed to the stage caps (bytes/time)
        // while it still clears the benefit floor.
        var k = index.longestRun(tags16: tags16)
        guard k > 0 else { return .skipped(.missAbsent) }
        var runBytes = 0
        var runSizes: [Int] = []
        var windowTags: [Data] = []
        while k > 0 {
            let matched = k * config.blockSize
            // Monotone impossibility test: shorter runs match strictly less
            // against the same bound, so failing here means no candidate can
            // pass and the loop can stop rather than count down to 1.
            guard matched - min(config.adoptionBoundTokens, matched)
                >= config.minEffectiveTokens
            else { return .skipped(.skippedCost) }
            guard let sizes = index.fileBytes(tags16: tags16[0 ..< k]) else {
                // Raced an eviction — re-probe.
                k = min(k - 1, index.longestRun(tags16: tags16))
                continue
            }
            runSizes = sizes
            runBytes = 0
            for size in sizes {
                let (sum, overflow) = runBytes.addingReportingOverflow(max(0, size))
                guard !overflow else { return .skipped(.skippedCapacity) }
                runBytes = sum
            }
            windowTags = windowSidecarTags(
                geometry: windowGeometry, chainHashes: hashes, cacheSalt: cacheScope, blocks: k,
                lookupKeys: lookupKeys)
            // Emptiness FIRST: `fileBytes` takes the index lock, and with the
            // sidecar knob off (the default) `windowTags` is always empty, so
            // testing it second bought an index-lock acquisition per trim
            // iteration — up to ~112 on a long prompt — to learn nothing.
            if !windowTags.isEmpty, let windowSizes = index.fileBytes(tags16: windowTags[...]) {
                for size in windowSizes {
                    let (sum, overflow) = runBytes.addingReportingOverflow(max(0, size))
                    guard !overflow else { return .skipped(.skippedCapacity) }
                    runBytes = sum
                }
            } else {
                // Incomplete tiling (or a raced eviction): a PARTIAL window is
                // not exact, so the whole window is dropped and the adopter
                // replays. Never shortens the block run.
                windowTags = []
            }
            // A restored window does NOT shorten the replay: no row can
            // install one, so every boundary is judged against the same
            // conservative bound whether or not its tiling is complete.
            if matched - min(config.adoptionBoundTokens, matched) >= config.minEffectiveTokens,
                runBytes <= config.maxStageBytes,
                SSDPrefixCachePolicy.estimatedStageMillis(bytes: runBytes) <= config.maxStageMillis
            {
                break
            }
            k -= 1
        }
        guard k > 0 else { return .skipped(.skippedCost) }

        return .candidate(StageMetadata(
            blockCount: k, fullTags: fullTags, tags16: tags16,
            runBytes: runBytes, runSizes: runSizes, windowTags: windowTags))
    }

    /// Truncated sidecar tags tiling the window that ends at block boundary
    /// `blocks`, oldest first. Empty when the boundary is shorter than one
    /// window — there is nothing to restore below `W` tokens, because the row
    /// legitimately has no older entries and cold prefill is already exact.
    private func windowSidecarTags(
        geometry: SSDWindowSidecarGeometry?,
        chainHashes: [Data],
        cacheSalt: String,
        blocks: Int,
        lookupKeys: SSDLookupKeys
    ) -> [Data] {
        guard let geometry, blocks >= geometry.blocksPerWindow, blocks <= chainHashes.count
        else { return [] }
        return (blocks - geometry.blocksPerWindow ..< blocks).map {
            lookupKeys.windowTag16(chainHash: chainHashes[$0], cacheSalt: cacheSalt)
        }
    }

}
