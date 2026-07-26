// Copyright © 2026 Eigen Labs.
//
// Pure-policy tests for the encrypted SSD production cache.

import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("PrefixCachePolicy")
struct PrefixCachePolicyTests {

    // MARK: - Env gate

    @Test("isEnabled: SSD defaults on and one explicit kill switch disables it")
    func envGate() {
        #expect(PrefixCachePolicy.isEnabled(environment: [:]))
        for on in ["1", "true", "yes", "on", " 1 ", "TRUE", "Yes", "ON"] {
            #expect(
                PrefixCachePolicy.isEnabled(environment: ["DARKBLOOM_PREFIX_CACHE": on]),
                "\(on) must enable")
        }
        for off in ["0", "false", "off", "no", "junk"] {
            #expect(
                !PrefixCachePolicy.isEnabled(environment: ["DARKBLOOM_PREFIX_CACHE": off]),
                "\(off) must disable the cache")
        }
        #expect(PrefixCachePolicy.isEnabled(environment: ["DARKBLOOM_PREFIX_CACHE": ""]))
    }

    // MARK: - Stats cadence

    @Test("statsIntervalSecs: default 120 / 0 disables / override / malformed")
    func statsInterval() {
        #expect(PrefixCachePolicy.statsIntervalSecs(environment: [:]) == 120)
        #expect(PrefixCachePolicy.statsIntervalSecs(
            environment: ["DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS": "0"]) == 0)
        #expect(PrefixCachePolicy.statsIntervalSecs(
            environment: ["DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS": "45"]) == 45)
        for bad in ["junk", "-5", ""] {
            #expect(PrefixCachePolicy.statsIntervalSecs(
                environment: ["DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS": bad]) == 120)
        }
    }

    // MARK: - SSD adoption bound

    /// Layer-kind fixture: `sliding` windowed layers of `window` tokens plus
    /// `full` full-attention layers (head shape irrelevant to the bound).
    private func kinds(sliding: Int, window: Int, full: Int) -> [CBv2LayerKind] {
        (0 ..< sliding).map { _ in
            CBv2LayerKind(
                attention: .slidingWindow(window), headDim: 64, kvHeads: 4, queryHeads: 8)
        } + (0 ..< full).map { _ in
            CBv2LayerKind(attention: .full, headDim: 64, kvHeads: 4, queryHeads: 8)
        }
    }

    @Test("typed capability enables frozen hybrids on both backends, at one shared bound")
    func reusableLayoutSafety() {
        let full = CBv2LayerKind(
            attention: .full, headDim: 64, kvHeads: 4, queryHeads: 8)
        let windowed = CBv2LayerKind(
            attention: .slidingWindow(128), headDim: 64, kvHeads: 4, queryHeads: 8)
        let sharedFull = CBv2LayerKind(
            attention: .full, sharesKVWithLayer: 0,
            headDim: 64, kvHeads: 4, queryHeads: 8)

        #expect(PrefixCachePolicy.prefixReuseCapability(
            layerKinds: [full, full], backendSelection: .contiguous).strategy == .direct)
        #expect(PrefixCachePolicy.prefixReuseCapability(
            layerKinds: [full, windowed], backendSelection: .paged).strategy == .tailReplay)
        #expect(PrefixCacheReplayStrategy(PrefixCachePolicy.prefixReuseCapability(
            layerKinds: [full, windowed], backendSelection: .paged)) == .tailReplay)
        #expect(PrefixCachePolicy.prefixReuseCapability(
            layerKinds: [windowed, sharedFull],
            backendSelection: .contiguous).unsupportedReason == .invalidLayout)

        let hybrid = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: [full, windowed, full],
            backendSelection: .contiguous)
        #expect(hybrid.isSupported)
        #expect(hybrid.strategy == .frozenFullReplay)
        #expect(hybrid.plan(matchedBoundary: 512)?.replayStart == 384)
        #expect(hybrid.plan(matchedBoundary: 512)?.restoredFullTokens == 512)

        // Paged hybrids WERE refused (`pagedHybridRequiresDualCursor`) until
        // WS-4.1's dual cursor landed, and for a while afterwards they were
        // supported but paid one extra `maxWindow` over contiguous, because
        // `PagedLayerCache.prefillKV` handed attention `gather ++ chunk` with
        // the chunk half freshly projected. That term is gone:
        // `prefillKVWritingChunk` now gathers the CACHED keys for a frozen
        // chunk, so `derive` returns `windowCount * maxWindow` from ONE shared
        // expression for both backends.
        //
        // So the invariant is no longer "paged is wider" but the strictly
        // stronger "paged is EQUAL". Asserted as equality rather than deleted:
        // this is the only place watching that relation, and a reintroduced
        // paged-specific slack term must break a test rather than quietly
        // widen the bound again.
        let pagedHybrid = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: [windowed, full],
            backendSelection: .paged)
        #expect(pagedHybrid.isSupported)
        #expect(pagedHybrid.unsupportedReason == nil)
        #expect(pagedHybrid.strategy == .frozenFullReplay)
        #expect(pagedHybrid.backend == .pagedFP16)
        let contiguousHybrid = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: [windowed, full],
            backendSelection: .contiguous)
        #expect(contiguousHybrid.backend == .contiguousUnquantized)
        #expect(
            pagedHybrid.conservativeReplayBoundTokens
                == contiguousHybrid.conservativeReplayBoundTokens,
            "the two backends must share one replay bound")
        // …and it is the real one, not two matching zeroes.
        #expect(pagedHybrid.conservativeReplayBoundTokens == 128)

        // A KILLED paged slot has degraded to a contiguous row and is resolved
        // as one. The bound can no longer show that (both are 128), so the
        // assertion moved to the field that still discriminates.
        let killedPagedHybrid = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: [windowed, full],
            backendSelection: .paged,
            pagedKilled: true)
        #expect(killedPagedHybrid.strategy == .frozenFullReplay)
        #expect(killedPagedHybrid.backend == .contiguousUnquantized)
        #expect(
            killedPagedHybrid.conservativeReplayBoundTokens
                == contiguousHybrid.conservativeReplayBoundTokens)
    }

    @Test("adoptionBoundTokens: windowCount × maxWindow; 0 for pure full attention")
    func adoptionBound() {
        // The two production shapes, exactly.
        #expect(PrefixCachePolicy.adoptionBoundTokens(
            layerKinds: kinds(sliding: 12, window: 128, full: 12)) == 1536)  // gpt-oss-20b
        #expect(PrefixCachePolicy.adoptionBoundTokens(
            layerKinds: kinds(sliding: 25, window: 1024, full: 5)) == 25600)  // gemma-4-26B
        // Pure full attention ⇒ 0 (every whole-block hit is adoptable).
        #expect(PrefixCachePolicy.adoptionBoundTokens(
            layerKinds: kinds(sliding: 0, window: 0, full: 24)) == 0)
        // Mixed windows: the LARGEST window bounds (mirror of
        // cbv2RequiredRecompute's maxWindow term).
        var mixed = kinds(sliding: 2, window: 128, full: 1)
        mixed[0].attention = .slidingWindow(512)
        #expect(PrefixCachePolicy.adoptionBoundTokens(layerKinds: mixed) == 2 * 512)
        #expect(PrefixCachePolicy.adoptionBoundTokens(layerKinds: []) == 0)
    }

    // MARK: - Residency- and backend-aware bound (WS-4.2)

    @Test("adoptionBoundTokens resolves the backend instead of hardcoding contiguous")
    func boundFollowsBackendSelection() {
        let gemma = kinds(sliding: 25, window: 1024, full: 5)
        // Derived from the SAME resolver as `prefixReuseCapability`, so the
        // two can never describe different backends for one slot. What that
        // buys is now invisible in the NUMBER: since the frozen paged gather
        // was proved exact, `derive` returns `windowCount * maxWindow` from one
        // shared expression for `.contiguousUnquantized` and `.pagedFP16`
        // alike, so every selection below reads 25,600. Resolution is
        // therefore asserted where it is still observable — on the resolved
        // capability's `backend` — and the numeric equality is pinned, so a
        // reintroduced paged slack term breaks this test instead of silently
        // re-diverging the two callers.
        for selection in [EngineV2KVBackendSelection.auto, .contiguous, .paged] {
            let capability = PrefixCachePolicy.prefixReuseCapability(
                layerKinds: gemma, backendSelection: selection)
            #expect(
                capability.backend
                    == (selection == .paged ? .pagedFP16 : .contiguousUnquantized),
                "\(selection) must resolve to its own backend")
            #expect(
                PrefixCachePolicy.adoptionBoundTokens(
                    layerKinds: gemma, backendSelection: selection) == 25_600)
            #expect(
                PrefixCachePolicy.adoptionBoundTokens(
                    capability: capability, layerKinds: gemma,
                    windowResidency: .replayed) == 25_600)
        }
        // The bound is READ from the capability it is handed, never re-derived
        // from `layerKinds` — `layerKinds` is consulted only for sidecar
        // geometry. Hand it gpt-oss's capability with gemma's layout and it
        // must answer gpt-oss's 1,536; a re-derivation (the shape a hardcoded
        // `.contiguousUnquantized` takes) would answer gemma's 25,600. This is
        // what still fails if the resolver is bypassed, now that both backends
        // agree numerically.
        let gpt = kinds(sliding: 12, window: 128, full: 12)
        #expect(
            PrefixCachePolicy.adoptionBoundTokens(
                capability: PrefixCachePolicy.prefixReuseCapability(
                    layerKinds: gpt, backendSelection: .paged),
                layerKinds: gemma,
                windowResidency: .replayed) == 1_536)
        // Paged's 25,600 sits EXACTLY on the long-hybrid threshold, so the
        // 1,536 floor still applies — narrowing the bound must not relax it.
        let paged = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: gemma, backendSelection: .paged)
        #expect(PrefixCachePolicy.minEffectiveTokens(
            capability: paged, adoptionBoundTokens: 25_600, environment: [:]) == 1_536)
        // A killed paged slot has degraded to a contiguous row; the bound no
        // longer moves, so the backend field carries the claim.
        #expect(
            PrefixCachePolicy.prefixReuseCapability(
                layerKinds: gemma, backendSelection: .paged, pagedKilled: true)
                .backend == .contiguousUnquantized)
        #expect(
            PrefixCachePolicy.adoptionBoundTokens(
                layerKinds: gemma, backendSelection: .paged, pagedKilled: true) == 25_600)
        // The shipped default is unchanged: no argument ⇒ replayed contiguous.
        #expect(PrefixCachePolicy.adoptionBoundTokens(layerKinds: gemma) == 25_600)
    }

    @Test("a restored window collapses the bound and, with it, the long-hybrid floor")
    func restoredWindowCollapsesTheFloor() {
        let gemma = kinds(sliding: 25, window: 1024, full: 5)
        let gpt = kinds(sliding: 12, window: 128, full: 12)
        let gemmaCapability = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: gemma, backendSelection: .contiguous)

        let replayed = PrefixCachePolicy.adoptionBoundTokens(
            capability: gemmaCapability, layerKinds: gemma, windowResidency: .replayed)
        let restored = PrefixCachePolicy.adoptionBoundTokens(
            capability: gemmaCapability, layerKinds: gemma,
            windowResidency: .restoredFromSidecar)
        #expect(replayed == 25_600)
        #expect(restored == 0)

        // The 1,536 long-hybrid floor exists because saving 1,024 tokens was
        // inside the noise of a 25,600-token replay. With no replay it does
        // not apply, so the generic 1,024 governs. Donation floor:
        // 25,600 + 1,536 = 27,136 ⇒ 0 + 1,024 = 1,024.
        #expect(PrefixCachePolicy.minEffectiveTokens(
            capability: gemmaCapability, adoptionBoundTokens: replayed,
            environment: [:]) == 1_536)
        #expect(PrefixCachePolicy.minEffectiveTokens(
            capability: gemmaCapability, adoptionBoundTokens: restored,
            environment: [:]) == 1_024)
        // The environment can still only RAISE it.
        #expect(PrefixCachePolicy.minEffectiveTokens(
            capability: gemmaCapability, adoptionBoundTokens: restored,
            environment: [SSDPrefixCachePolicy.minEffectiveTokensFlag: "2048"]) == 2_048)

        // gpt-oss-20b's 128-token window does not tile into 256-token blocks,
        // so asserting residency for it must still fail closed to replay.
        let gptCapability = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: gpt, backendSelection: .contiguous)
        #expect(PrefixCachePolicy.adoptionBoundTokens(
            capability: gptCapability, layerKinds: gpt,
            windowResidency: .restoredFromSidecar) == 1_536)
    }

    @Test("residency stays REPLAYED while no row can install a restored window")
    func residencyFailsClosedWithoutAConsumer() {
        let gemma = kinds(sliding: 25, window: 1024, full: 5)
        let gpt = kinds(sliding: 12, window: 128, full: 12)
        let on = [SSDPrefixCachePolicy.windowSidecarFlag: "1"]

        // Nothing in this repo consumes a staged window: there is no
        // `restoreWindow(_:at:)` on any row, and nothing calls
        // `SSDPrefixCache.stagedWindow(requestID:)`. Every backend must
        // therefore answer `false`, killed or not.
        for selection in [EngineV2KVBackendSelection.auto, .contiguous, .paged] {
            for killed in [false, true] {
                #expect(
                    !PrefixCachePolicy.windowRestoreSupported(
                        backendSelection: selection, pagedKilled: killed),
                    "\(selection)/killed=\(killed) must not claim a restore consumer")
                // …so the residency is `.replayed` with the knob ON, for a
                // layout that tiles perfectly, on every backend.
                #expect(
                    PrefixCachePolicy.windowResidency(
                        layerKinds: gemma, backendSelection: selection,
                        pagedKilled: killed, environment: on) == .replayed)
                #expect(
                    PrefixCachePolicy.windowResidency(
                        layerKinds: gemma, backendSelection: selection,
                        pagedKilled: killed, environment: [:]) == .replayed,
                    "default must not change the shipped floor")
                #expect(
                    PrefixCachePolicy.windowResidency(
                        layerKinds: gpt, backendSelection: selection,
                        pagedKilled: killed, environment: on) == .replayed)
            }
        }

        // The consequence that matters: the knob cannot collapse gemma-4's
        // replay bound, so the cache can never advertise a matched prefix as
        // free while the engine still replays 25,600 tokens. This is the exact
        // composition `SSDPrefixCacheFactory.make` performs.
        let capability = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: gemma, backendSelection: .contiguous)
        #expect(PrefixCachePolicy.adoptionBoundTokens(
            capability: capability,
            layerKinds: gemma,
            windowResidency: PrefixCachePolicy.windowResidency(
                layerKinds: gemma, backendSelection: .contiguous, environment: on)) == 25_600)

        // …while the knob still switches the sidecar format on, so the write
        // and read paths stay exercised rather than becoming dead code.
        #expect(SSDPrefixCachePolicy.windowSidecarEnabled(environment: on))
        #expect(
            SSDWindowSidecarGeometry.derive(
                layerKinds: gemma, blockSize: PrefixCachePolicy.blockSize) != nil)

        // The flip is these two constants plus a consumer.
        #expect(!PrefixCachePolicy.contiguousWindowRestoreLanded)
        #expect(!PrefixCachePolicy.pagedWindowRestoreLanded)
    }

    @Test("Gemma QAT and GPT-OSS layouts qualify for v2 on both backends")
    func productionHybridCapabilities() {
        let sliding128 = CBv2LayerKind(
            attention: .slidingWindow(128),
            headDim: 64,
            kvHeads: 8,
            queryHeads: 64)
        let gptFull = CBv2LayerKind(
            attention: .full,
            headDim: 64,
            kvHeads: 8,
            queryHeads: 64)
        let gpt = (0 ..< 12).flatMap { _ in [sliding128, gptFull] }

        let sliding1024 = CBv2LayerKind(
            attention: .slidingWindow(1024),
            headDim: 256,
            kvHeads: 1,
            queryHeads: 16)
        let gemmaFull = CBv2LayerKind(
            attention: .full,
            headDim: 256,
            kvHeads: 1,
            queryHeads: 16)
        let gemma = (0 ..< 5).flatMap { _ in
            Array(repeating: sliding1024, count: 5) + [gemmaFull]
        }

        for kinds in [gpt, gemma] {
            let contiguous = PrefixCachePolicy.prefixReuseCapability(
                layerKinds: kinds,
                backendSelection: .contiguous)
            #expect(contiguous.isSupported)
            #expect(contiguous.strategy == .frozenFullReplay)

            // Paged qualifies too since WS-4.1's dual cursor, and since the
            // frozen chunk gather was proved exact it qualifies at contiguous's
            // bound exactly — no extra `maxWindow` for a freshly-projected
            // chunk half, because there is no longer a freshly-projected half.
            let paged = PrefixCachePolicy.prefixReuseCapability(
                layerKinds: kinds,
                backendSelection: .paged)
            #expect(paged.isSupported)
            #expect(paged.unsupportedReason == nil)
            #expect(paged.strategy == .frozenFullReplay)
            #expect(paged.backend == .pagedFP16)
            #expect(contiguous.backend == .contiguousUnquantized)
            #expect(
                paged.conservativeReplayBoundTokens
                    == contiguous.conservativeReplayBoundTokens,
                "both production layouts must bound identically on both backends")
        }
        #expect(PrefixCachePolicy.adoptionBoundTokens(layerKinds: gpt) == 1_536)
        #expect(PrefixCachePolicy.adoptionBoundTokens(layerKinds: gemma) == 25_600)
        let gptCapability = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: gpt,
            backendSelection: .contiguous)
        let gemmaCapability = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: gemma,
            backendSelection: .contiguous)
        #expect(PrefixCachePolicy.minEffectiveTokens(
            capability: gptCapability,
            environment: [:]) == 1_024)
        #expect(PrefixCachePolicy.minEffectiveTokens(
            capability: gemmaCapability,
            environment: [:]) == 1_536)
        #expect(PrefixCachePolicy.minEffectiveTokens(
            capability: gemmaCapability,
            environment: [
                SSDPrefixCachePolicy.minEffectiveTokensFlag: "2048"
            ]) == 2_048)
    }

    @Test("construction failures map to bounded eligibility reasons")
    func constructionFailureReasons() {
        let windowed = CBv2LayerKind(
            attention: .slidingWindow(128),
            headDim: 64,
            kvHeads: 8,
            queryHeads: 64)
        let full = CBv2LayerKind(
            attention: .full,
            headDim: 64,
            kvHeads: 8,
            queryHeads: 64)
        let pagedHybrid = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: [windowed, full],
            backendSelection: .paged)
        let box = PrefixCacheConstructionStatusBox()

        // `.unsupportedPlan` on a paged hybrid used to report
        // `.pagedHybridUnsupported`. It cannot any more: that branch in
        // `PrefixCacheEligibilityStatus` keys off the capability carrying
        // `paged_hybrid_requires_dual_cursor`, and since WS-4.1's dual cursor
        // landed nothing produces that reason — `derive` never sets it and the
        // capability's memberwise init is private, so it is unreachable from
        // any input. A refused paged plan now lands on the generic layout
        // reason. (The dead branch itself is in a file outside this track;
        // flagged to the lead rather than deleted here.)
        box.record(failure: .unsupportedPlan, capability: pagedHybrid)
        #expect(pagedHybrid.unsupportedReason == nil)
        #expect(box.snapshot?.state == .disabled)
        #expect(box.snapshot?.reason == .unsupportedLayout)

        box.record(failure: .missingWeightHash, capability: pagedHybrid)
        #expect(box.snapshot?.state == .disabled)
        #expect(box.snapshot?.reason == .weightHashUnavailable)

        box.record(failure: .unsafePath, capability: pagedHybrid)
        #expect(box.snapshot?.state == .error)
        #expect(box.snapshot?.reason == .diskUnavailable)
    }

}
