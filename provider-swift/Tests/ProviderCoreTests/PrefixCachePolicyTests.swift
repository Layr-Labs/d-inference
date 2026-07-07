// Copyright © 2026 Eigen Labs.
//
// Pure-policy tests for `PrefixCachePolicy` — the scheduler-free gate /
// budget / carve helper that funds the v2 engine's RAM-only
// `PrefixCacheV2` (T-041). No engines, no weights, no environment
// mutation: env + physical memory are injected.

import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("PrefixCachePolicy")
struct PrefixCachePolicyTests {

    private static let gib = 1_073_741_824

    // MARK: - Env gate

    @Test("isEnabled: default ON; only an explicit opt-out disables")
    func envGate() {
        // Unset ⇒ enabled (default ON — the legacy contract).
        #expect(PrefixCachePolicy.isEnabled(environment: [:]))
        // Explicit opt-outs, incl. case/whitespace normalization.
        for off in ["0", "false", "off", "no", " 0 ", "FALSE", "Off", "NO"] {
            #expect(
                !PrefixCachePolicy.isEnabled(environment: ["DARKBLOOM_PREFIX_CACHE": off]),
                "\(off) must disable")
        }
        // Anything else — including affirmatives and garbage — keeps the
        // default ON (identical to the legacy env check).
        for on in ["1", "true", "yes", "on", "junk", ""] {
            #expect(
                PrefixCachePolicy.isEnabled(environment: ["DARKBLOOM_PREFIX_CACHE": on]),
                "\(on) must keep the cache enabled")
        }
    }

    // MARK: - Budget

    @Test("budgetBytes: MAX_GB override wins; invalid falls back to physical/8")
    func budget() {
        let physical = 128 * Self.gib
        // Valid override (integer and fractional GB).
        #expect(PrefixCachePolicy.budgetBytes(
            environment: ["DARKBLOOM_PREFIX_CACHE_MAX_GB": "2"],
            physicalMemory: physical) == 2 * Self.gib)
        #expect(PrefixCachePolicy.budgetBytes(
            environment: ["DARKBLOOM_PREFIX_CACHE_MAX_GB": "0.5"],
            physicalMemory: physical) == Self.gib / 2)
        // Unset / malformed / non-positive / non-finite / overflowing ⇒
        // physical/8 (the legacy default policy, verbatim).
        for bad in [nil, "abc", "-1", "0", "inf", "nan", "1e30"] as [String?] {
            var env: [String: String] = [:]
            if let bad { env["DARKBLOOM_PREFIX_CACHE_MAX_GB"] = bad }
            #expect(
                PrefixCachePolicy.budgetBytes(environment: env, physicalMemory: physical)
                    == physical / 8,
                "\(bad ?? "unset") must fall back to physical/8")
        }
        // Degenerate physical memory keeps the ≥1 floor.
        #expect(PrefixCachePolicy.budgetBytes(environment: [:], physicalMemory: 4) == 1)
    }

    @Test("legacy resolveMemoryBudget delegates to the shared policy (no drift)")
    func legacyDelegation() {
        for (envGB, physical) in [(nil, 64 * Self.gib), (2.0, 64 * Self.gib), (-3.0, 8 * Self.gib)]
            as [(Double?, Int)]
        {
            #expect(
                BatchScheduler.resolveMemoryBudget(envGB: envGB, physicalMemory: physical)
                    == PrefixCachePolicy.resolveMemoryBudget(
                        envGB: envGB, physicalMemory: physical))
        }
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
        // The legacy resolver rides the same policy.
        #expect(BatchScheduler.resolveStatsInterval(env: nil) == 120)
        #expect(BatchScheduler.resolveStatsInterval(env: "0") == 0)
        #expect(BatchScheduler.resolveStatsInterval(env: "30") == 30)
    }

    // MARK: - Per-model funding gate (adoption bound)

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

    @Test("maxAdoptionBoundTokens: default 4096 / 0 never funds / override / malformed")
    func adoptionBoundThreshold() {
        #expect(PrefixCachePolicy.maxAdoptionBoundTokens(environment: [:]) == 4096)
        #expect(PrefixCachePolicy.maxAdoptionBoundTokens(
            environment: ["DARKBLOOM_PREFIX_CACHE_MAX_ADOPTION_BOUND_TOKENS": "0"]) == 0)
        #expect(PrefixCachePolicy.maxAdoptionBoundTokens(
            environment: ["DARKBLOOM_PREFIX_CACHE_MAX_ADOPTION_BOUND_TOKENS": "30000"]) == 30000)
        for bad in ["junk", "-5", ""] {
            #expect(PrefixCachePolicy.maxAdoptionBoundTokens(
                environment: ["DARKBLOOM_PREFIX_CACHE_MAX_ADOPTION_BOUND_TOKENS": bad]) == 4096,
                "\(bad) must fall back to the default")
        }
    }

    @Test("shouldFund: gpt-oss funded, gemma unfunded at the default; override + never-fund")
    func fundingGate() {
        // Default threshold: gpt-oss (1,536) funds, gemma (25,600) does not.
        #expect(PrefixCachePolicy.shouldFund(adoptionBoundTokens: 1536, environment: [:]))
        #expect(!PrefixCachePolicy.shouldFund(adoptionBoundTokens: 25600, environment: [:]))
        // Boundary: exactly at the cap funds.
        #expect(PrefixCachePolicy.shouldFund(adoptionBoundTokens: 4096, environment: [:]))
        #expect(!PrefixCachePolicy.shouldFund(adoptionBoundTokens: 4097, environment: [:]))
        // Bound 0 / unknown-treated-as-0 (pure full attention) funds.
        #expect(PrefixCachePolicy.shouldFund(adoptionBoundTokens: 0, environment: [:]))
        // Override raises the cap: gemma becomes fundable.
        let raised = ["DARKBLOOM_PREFIX_CACHE_MAX_ADOPTION_BOUND_TOKENS": "26000"]
        #expect(PrefixCachePolicy.shouldFund(adoptionBoundTokens: 25600, environment: raised))
        // 0 ⇒ never fund ANY model, including bound-0 ones.
        let never = ["DARKBLOOM_PREFIX_CACHE_MAX_ADOPTION_BOUND_TOKENS": "0"]
        #expect(!PrefixCachePolicy.shouldFund(adoptionBoundTokens: 0, environment: never))
        #expect(!PrefixCachePolicy.shouldFund(adoptionBoundTokens: 1536, environment: never))
    }

    // MARK: - Carve

    @Test("carve: normal split conserves bytes (engine + prefix == slot)")
    func carveNormal() {
        let carve = PrefixCachePolicy.carve(
            slotKVBytesCapacity: 10 * Self.gib,
            requestedBudgetBytes: 2 * Self.gib,
            kvBytesPerToken: 4096)
        #expect(carve.engineKVBytesCapacity == 8 * Self.gib)
        #expect(carve.prefixCacheBudgetBytes == 2 * Self.gib)
        #expect(carve.engineKVBytesCapacity + carve.prefixCacheBudgetBytes == 10 * Self.gib)
    }

    @Test("carve: requested 0 (gate off) is a passthrough")
    func carveDisabled() {
        let carve = PrefixCachePolicy.carve(
            slotKVBytesCapacity: 10 * Self.gib, requestedBudgetBytes: 0, kvBytesPerToken: 4096)
        #expect(carve == PrefixCachePolicy.Carve(
            engineKVBytesCapacity: 10 * Self.gib, prefixCacheBudgetBytes: 0))
    }

    @Test("carve: floor guard shrinks the PREFIX budget, never live KV")
    func carveFloorGuard() {
        // Requested budget would leave the engine under the 1 GiB
        // serviceable floor ⇒ the prefix shrinks to slot − floor and the
        // engine keeps EXACTLY the floor (live serving wins).
        let carve = PrefixCachePolicy.carve(
            slotKVBytesCapacity: 3 * Self.gib,
            requestedBudgetBytes: 16 * Self.gib,
            kvBytesPerToken: 4096)
        #expect(carve.engineKVBytesCapacity == 1 * Self.gib)
        #expect(carve.prefixCacheBudgetBytes == 2 * Self.gib)
    }

    @Test("carve: a grant at/below the floor funds no cache at all")
    func carveTinyGrant() {
        for slot in [Self.gib, Self.gib / 2, 0, -5] {
            let carve = PrefixCachePolicy.carve(
                slotKVBytesCapacity: slot,
                requestedBudgetBytes: 4 * Self.gib,
                kvBytesPerToken: 4096)
            #expect(carve.prefixCacheBudgetBytes == 0, "slot \(slot) must not fund a cache")
            #expect(carve.engineKVBytesCapacity == max(0, slot), "engine keeps everything")
        }
    }

    @Test("carve: a budget below one hash block degrades to off")
    func carveOneBlockViability() {
        // 4 MiB/token × 256-token block = 1 GiB per block; a 512 MiB budget
        // could never retain a single donation ⇒ off (legacy maxBlocks ≥ 1
        // guard, reproduced).
        let carve = PrefixCachePolicy.carve(
            slotKVBytesCapacity: 64 * Self.gib,
            requestedBudgetBytes: Self.gib / 2,
            kvBytesPerToken: 4 * 1024 * 1024)
        #expect(carve.prefixCacheBudgetBytes == 0)
        #expect(carve.engineKVBytesCapacity == 64 * Self.gib)
        // Unknown rate (0) skips the block check — the byte budget stands.
        let unknownRate = PrefixCachePolicy.carve(
            slotKVBytesCapacity: 64 * Self.gib,
            requestedBudgetBytes: Self.gib / 2,
            kvBytesPerToken: 0)
        #expect(unknownRate.prefixCacheBudgetBytes == Self.gib / 2)
        #expect(unknownRate.engineKVBytesCapacity + unknownRate.prefixCacheBudgetBytes
            == 64 * Self.gib)
    }

    // MARK: - Construction

    @Test("makePrefixCache: funded ⇒ blockSize 256 + model namespace + byte budget; 0 ⇒ nil")
    func makeCache() throws {
        #expect(PrefixCachePolicy.makePrefixCache(modelId: "m", budgetBytes: 0) == nil)
        #expect(PrefixCachePolicy.makePrefixCache(modelId: "m", budgetBytes: -1) == nil)
        let cache = PrefixCachePolicy.makePrefixCache(
            modelId: "gpt-oss-20b", budgetBytes: 2 * Self.gib)
        let config = try #require(cache).config
        #expect(config.blockSize == 256)
        #expect(config.blockSize == CBv2BlockHasher.defaultBlockSize)
        #expect(config.modelName == "gpt-oss-20b")
        #expect(config.maxBytes == 2 * Self.gib)
        // Default materializeOnDonate stays true (required pairing for any
        // backend with recyclable snapshot storage — engine precondition).
        #expect(config.materializeOnDonate)
        // Cache-level salt stays empty: tenant scoping is PER REQUEST
        // (CBv2Request.cacheSalt), not cache-level.
        #expect(config.cacheSalt.isEmpty)
    }
}
