import Foundation
import Testing

@testable import ProviderCore

@Suite("RAM-only prefix tier switches and budget")
struct MemoryOnlyPrefixCachePolicyTests {
    private static let gib = 1.0 * Double(1 << 30)

    @Test("auto by default; off words, unknown values and the global disable turn it off")
    func mode() {
        let key = MemoryOnlyPrefixCachePolicy.modeEnvironmentKey
        #expect(MemoryOnlyPrefixCachePolicy.isEnabled(environment: [:]))
        #expect(MemoryOnlyPrefixCachePolicy.isEnabled(environment: [key: " AUTO "]))
        #expect(MemoryOnlyPrefixCachePolicy.isEnabled(environment: [key: ""]))
        for value in ["off", "0", "false", "no", "on", "1", "yes", "sometimes"] {
            #expect(!MemoryOnlyPrefixCachePolicy.isEnabled(environment: [key: value]), "\(value)")
        }
        #expect(!MemoryOnlyPrefixCachePolicy.isEnabled(environment: ["DARKBLOOM_PREFIX_CACHE": "0"]))
        #expect(MemoryOnlyPrefixCachePolicy.budgetBytes(
            fleetKVHeadroomBytes: 64 << 30, environment: [key: "off"]) == 0)
    }

    @Test("the tier is attached by default, and never with a resident tier, when off, or for an excluded model")
    func attachRules() {
        #expect(MemoryOnlyPrefixCachePolicy.attachesTier(excludedModel: false, environment: [:]))
        #expect(!MemoryOnlyPrefixCachePolicy.attachesTier(excludedModel: true, environment: [:]))
        for environment in [
            ["DARKBLOOM_PREFIX_CACHE_MEMORY": "1"], [MemoryOnlyPrefixCachePolicy.modeEnvironmentKey: "off"],
            ["DARKBLOOM_PREFIX_CACHE": "0"],
        ] {
            #expect(!MemoryOnlyPrefixCachePolicy.attachesTier(excludedModel: false, environment: environment),
                    "\(environment)")
        }
    }

    @Test("a memory_only request keeps its prefix cache only where the tier is offered")
    func submissionPolicy() {
        let marked = PrefixCacheSubmissionPolicy(cachePolicy: .memoryOnly, memoryOnlyTierAvailable: true)
        #expect(marked.usesMemoryOnlyTier && !marked.usesSSDTier && marked.cacheEnabled(true))
        #expect(!marked.cacheEnabled(false))
        let noTier = PrefixCacheSubmissionPolicy(cachePolicy: .memoryOnly, memoryOnlyTierAvailable: false)
        #expect(!noTier.usesMemoryOnlyTier && !noTier.usesSSDTier && !noTier.cacheEnabled(true))
        let ordinary = PrefixCacheSubmissionPolicy(cachePolicy: .default, memoryOnlyTierAvailable: true)
        #expect(ordinary.usesSSDTier && !ordinary.usesMemoryOnlyTier && ordinary.cacheEnabled(true))
    }

    @Test("the MiB setting replaces the cap but never the quarter of headroom")
    func cap() {
        let key = MemoryOnlyPrefixCachePolicy.maximumMegabytesEnvironmentKey
        #expect(MemoryOnlyPrefixCachePolicy.capBytes(environment: [:]) == 8 << 30)
        #expect(MemoryOnlyPrefixCachePolicy.capBytes(environment: [key: "2048"]) == 2 << 30)
        for value in ["0", "-1", "lots", ""] {
            #expect(MemoryOnlyPrefixCachePolicy.capBytes(environment: [key: value]) == 8 << 30, "\(value)")
        }
        #expect(MemoryOnlyPrefixCachePolicy.budgetBytes(
            fleetKVHeadroomBytes: 200 << 30, environment: [key: "32768"]) == 32 << 30)
        #expect(MemoryOnlyPrefixCachePolicy.budgetBytes(
            fleetKVHeadroomBytes: 40 << 30, environment: [key: "32768"]) == 10 << 30)
        #expect(MemoryOnlyPrefixCachePolicy.budgetBytes(
            fleetKVHeadroomBytes: 40 << 30, environment: [key: "512"]) == 0)
    }

    /// The design table: one model resident, the default 4 GiB operator
    /// reserve, the code's activation floors and the measured resident weights.
    @Test("per-chip budgets for the four main models", arguments: [
        (16, [0.0, 0, 0, 0]),
        (24, [1.3125, 0, 0, 2.2025]),
        (32, [3.3125, 2.255, 0, 4.2025]),
        (48, [7.1125, 6.055, 4.47, 8]),
        (64, [8.0, 8, 8, 8]), (96, [8.0, 8, 8, 8]), (128, [8.0, 8, 8, 8]),
        (192, [8.0, 8, 8, 8]), (256, [8.0, 8, 8, 8]), (512, [8.0, 8, 8, 8]),
    ])
    func perChipBudget(memoryGiB: Int, expectedGiB: [Double]) {
        let models: [(id: String, weightsGiB: Double)] = [
            ("gpt-oss-20b", 11.25), ("gemma-4-26b-qat-4bit", 13.48),
            ("qwen3.6-35b-a3b-vl-mtp-mxfp8", 19.82), ("Qwen3.5-9B", 5.69),
        ]
        for (model, expected) in zip(models, expectedGiB) {
            let headroom = UnifiedMemoryCap.kvBudgetBytes(
                physicalBytes: UInt64(memoryGiB) << 30,
                residentWeightBytes: UInt64(model.weightsGiB * Self.gib),
                activationReserveBytes: UnifiedMemoryCap.activationFloorBytes(forModelIDs: [model.id]),
                configReserveBytes: 4 << 30)
            let budget = Double(MemoryOnlyPrefixCachePolicy.budgetBytes(
                fleetKVHeadroomBytes: headroom, environment: [:])) / Self.gib
            #expect(abs(budget - expected) < 0.01, "\(memoryGiB) GiB \(model.id): \(budget) GiB")
        }
    }
}
