// Copyright © 2026 Eigen Labs.
//
// Pure-arithmetic tests for the KV re-slice policy
// (`EngineV2KVSizing.resliceGrants`) — the multi-model co-residency fix.
// The orchestration (shrink/build/restore against live engines) is covered
// in EngineV2ProductionWiringTests; this file pins the POLICY:
// proportional fair shares, the single-model full-budget rule, the
// equal-split degenerate, the Σ ≤ budget invariant, and the
// serviceability floor.

import Foundation
import Testing

@testable import ProviderCore

@Suite("EngineV2 KV re-slice policy (pure)")
struct EngineV2ResliceTests {

    private static let gib: UInt64 = 1024 * 1024 * 1024

    /// Production-shaped inputs: gemma-4-26B-qat (20,480 B/tok fp16, 262k
    /// context → capped at 131,072) and gpt-oss-20b (24,576 B/tok, 131k).
    private var gemma: EngineV2KVSizing.ResliceSlot {
        .init(modelId: "gemma-4-26b-qat-4bit", fp16KVBytesPerToken: 20_480, maxContextLength: 262_144)
    }
    private var gptoss: EngineV2KVSizing.ResliceSlot {
        .init(modelId: "gpt-oss-20b", fp16KVBytesPerToken: 24_576, maxContextLength: 131_072)
    }

    @Test("single model keeps the FULL fleet budget (never a static N-way split)")
    func singleModelFullBudget() {
        let budget = 20 * Self.gib
        let grants = EngineV2KVSizing.resliceGrants(
            existing: [], newcomer: gemma, fleetKVBudgetBytes: budget)
        #expect(grants == ["gemma-4-26b-qat-4bit": Int(budget)])
        // Same for a lone survivor after an unload.
        let survivors = EngineV2KVSizing.resliceGrants(
            existing: [gptoss], newcomer: nil, fleetKVBudgetBytes: budget)
        #expect(survivors == ["gpt-oss-20b": Int(budget)])
    }

    @Test("two models share ∝ rate × min(context, 131_072)")
    func proportionalShares() throws {
        let budget = 22 * Self.gib
        let grants = EngineV2KVSizing.resliceGrants(
            existing: [gemma], newcomer: gptoss, fleetKVBudgetBytes: budget)
        let wGemma = 20_480.0 * 131_072.0  // context capped at 131_072
        let wGpt = 24_576.0 * 131_072.0
        let expectedGemma = UInt64(Double(budget) * (wGemma / (wGemma + wGpt)))
        let expectedGpt = UInt64(Double(budget) * (wGpt / (wGemma + wGpt)))
        let gemmaGrant = try #require(grants["gemma-4-26b-qat-4bit"])
        let gptGrant = try #require(grants["gpt-oss-20b"])
        // Floor-division smear ≤ a few bytes; assert within 1 KiB.
        #expect(abs(Int64(gemmaGrant) - Int64(expectedGemma)) <= 1024)
        #expect(abs(Int64(gptGrant) - Int64(expectedGpt)) <= 1024)
        // gpt-oss has the larger weight (higher fp16 rate at equal capped
        // context) → the larger share.
        #expect(gptGrant > gemmaGrant)
        // Σ(grants) ≤ budget — the process-wide invariant.
        #expect(UInt64(gemmaGrant) + UInt64(gptGrant) <= budget)
    }

    @Test("context cap: a 262k-context model earns no more budget than a 131k one at equal rate")
    func contextCapBoundsWeights() {
        let budget = 10 * Self.gib
        let longContext = EngineV2KVSizing.ResliceSlot(
            modelId: "long", fp16KVBytesPerToken: 10_000, maxContextLength: 1_000_000)
        let cappedContext = EngineV2KVSizing.ResliceSlot(
            modelId: "capped", fp16KVBytesPerToken: 10_000, maxContextLength: 131_072)
        let grants = EngineV2KVSizing.resliceGrants(
            existing: [longContext], newcomer: cappedContext, fleetKVBudgetBytes: budget)
        // Equal weights after the cap ⇒ equal shares.
        #expect(grants["long"] == grants["capped"])
    }

    @Test("unknown context defaults to the cap; unknown rate degrades ALL to equal split")
    func degenerateInputs() {
        let budget = 9 * Self.gib
        // Unknown context (0) uses the cap → equal to an explicitly-capped peer.
        let noContext = EngineV2KVSizing.ResliceSlot(
            modelId: "no-context", fp16KVBytesPerToken: 10_000, maxContextLength: 0)
        let withContext = EngineV2KVSizing.ResliceSlot(
            modelId: "with-context", fp16KVBytesPerToken: 10_000, maxContextLength: 131_072)
        let contextGrants = EngineV2KVSizing.resliceGrants(
            existing: [noContext], newcomer: withContext, fleetKVBudgetBytes: budget)
        #expect(contextGrants["no-context"] == contextGrants["with-context"])

        // Unknown rate (0) ⇒ the WHOLE slice equal-splits (never a mix of
        // real and guessed weights).
        let unknownRate = EngineV2KVSizing.ResliceSlot(
            modelId: "unknown-rate", fp16KVBytesPerToken: 0, maxContextLength: 131_072)
        let grants = EngineV2KVSizing.resliceGrants(
            existing: [gemma, gptoss], newcomer: unknownRate, fleetKVBudgetBytes: budget)
        let third = Int(budget / 3)
        #expect(grants["gemma-4-26b-qat-4bit"] == third)
        #expect(grants["gpt-oss-20b"] == third)
        #expect(grants["unknown-rate"] == third)
    }

    @Test("empty inputs yield no grants; zero budget yields zero grants")
    func emptyAndZero() {
        #expect(EngineV2KVSizing.resliceGrants(
            existing: [], newcomer: nil, fleetKVBudgetBytes: 10 * Self.gib).isEmpty)
        let grants = EngineV2KVSizing.resliceGrants(
            existing: [gemma], newcomer: gptoss, fleetKVBudgetBytes: 0)
        #expect(grants.values.allSatisfy { $0 == 0 })
    }

    @Test("three-way slice: Σ ≤ budget and ordering follows the weights")
    func threeWaySlice() {
        let budget = 30 * Self.gib
        let third = EngineV2KVSizing.ResliceSlot(
            modelId: "small-model", fp16KVBytesPerToken: 4_096, maxContextLength: 32_768)
        let grants = EngineV2KVSizing.resliceGrants(
            existing: [gemma, gptoss], newcomer: third, fleetKVBudgetBytes: budget)
        #expect(grants.count == 3)
        let sum = grants.values.reduce(UInt64(0)) { $0 + UInt64($1) }
        #expect(sum <= budget)
        // Weight order: gpt-oss > gemma > small.
        #expect(grants["gpt-oss-20b"]! > grants["gemma-4-26b-qat-4bit"]!)
        #expect(grants["gemma-4-26b-qat-4bit"]! > grants["small-model"]!)
    }

    @Test("serviceability floor: 1 GiB per grant, checked over ALL grants")
    func serviceabilityFloor() {
        #expect(EngineV2KVSizing.minimumServiceableGrantBytes == 1 * Self.gib)
        // All above the floor → passes.
        #expect(EngineV2KVSizing.resliceMeetsServiceabilityFloor([
            "a": Int(2 * Self.gib), "b": Int(1 * Self.gib),
        ]))
        // ANY grant below the floor → refused.
        #expect(!EngineV2KVSizing.resliceMeetsServiceabilityFloor([
            "a": Int(20 * Self.gib), "b": Int(1 * Self.gib) - 1,
        ]))
        #expect(!EngineV2KVSizing.resliceMeetsServiceabilityFloor(["a": 0]))
        // Vacuously true for no grants (unload path with no survivors).
        #expect(EngineV2KVSizing.resliceMeetsServiceabilityFloor([:]))
    }

    @Test("load-then-unload round trip restores the original grant")
    func loadUnloadRoundTrip() {
        // Budgets differ while B is resident (its weights shrink the fleet
        // budget), but after B unloads the recomputed single-model slice
        // equals the original full budget — the regrow invariant the
        // orchestration relies on.
        let budgetAloneA = 20 * Self.gib
        let before = EngineV2KVSizing.resliceGrants(
            existing: [], newcomer: gemma, fleetKVBudgetBytes: budgetAloneA)
        let after = EngineV2KVSizing.resliceGrants(
            existing: [gemma], newcomer: nil, fleetKVBudgetBytes: budgetAloneA)
        #expect(before == after)
    }
}
