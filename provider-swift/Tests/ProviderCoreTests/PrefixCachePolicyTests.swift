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

    @Test("typed capability enables frozen contiguous hybrids and rejects paged hybrids")
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

        let pagedHybrid = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: [windowed, full],
            backendSelection: .paged)
        #expect(!pagedHybrid.isSupported)
        #expect(pagedHybrid.unsupportedReason == .pagedHybridRequiresDualCursor)

        let killedPagedHybrid = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: [windowed, full],
            backendSelection: .paged,
            pagedKilled: true)
        #expect(killedPagedHybrid.strategy == .frozenFullReplay)
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
        // Same numeric bound on every selection today (it is windowCount ×
        // maxWindow, which no backend changes) — but it is now derived from
        // the SAME resolver as `prefixReuseCapability`, so the two can never
        // describe different backends for one slot.
        for selection in [
            EngineV2KVBackendSelection.auto, .contiguous, .paged,
        ] {
            let capability = PrefixCachePolicy.prefixReuseCapability(
                layerKinds: gemma, backendSelection: selection)
            #expect(
                PrefixCachePolicy.adoptionBoundTokens(
                    layerKinds: gemma, backendSelection: selection) == 25_600)
            #expect(
                PrefixCachePolicy.adoptionBoundTokens(
                    capability: capability, layerKinds: gemma,
                    windowResidency: .replayed) == 25_600)
        }
        // A killed paged slot has degraded to a contiguous row.
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

    @Test("windowResidency is off unless the operator knob is set AND the layout tiles")
    func residencyGate() {
        let gemma = kinds(sliding: 25, window: 1024, full: 5)
        let gpt = kinds(sliding: 12, window: 128, full: 12)
        let on = [SSDPrefixCachePolicy.windowSidecarFlag: "1"]
        for selection in [EngineV2KVBackendSelection.auto, .contiguous, .paged] {
            #expect(
                PrefixCachePolicy.windowResidency(
                    layerKinds: gemma, backendSelection: selection,
                    environment: [:]) == .replayed,
                "default must not change the shipped floor")
            #expect(
                PrefixCachePolicy.windowResidency(
                    layerKinds: gemma, backendSelection: selection,
                    environment: on) == .restoredFromSidecar)
            #expect(
                PrefixCachePolicy.windowResidency(
                    layerKinds: gpt, backendSelection: selection,
                    environment: on) == .replayed)
        }
    }

    @Test("Gemma QAT and GPT-OSS contiguous layouts qualify for v2; paged stays cold")
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

            let paged = PrefixCachePolicy.prefixReuseCapability(
                layerKinds: kinds,
                backendSelection: .paged)
            #expect(!paged.isSupported)
            #expect(paged.unsupportedReason == .pagedHybridRequiresDualCursor)
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

        box.record(failure: .unsupportedPlan, capability: pagedHybrid)
        #expect(box.snapshot?.state == .disabled)
        #expect(box.snapshot?.reason == .pagedHybridUnsupported)

        box.record(failure: .missingWeightHash, capability: pagedHybrid)
        #expect(box.snapshot?.state == .disabled)
        #expect(box.snapshot?.reason == .weightHashUnavailable)

        box.record(failure: .unsafePath, capability: pagedHybrid)
        #expect(box.snapshot?.state == .error)
        #expect(box.snapshot?.reason == .diskUnavailable)
    }

}
