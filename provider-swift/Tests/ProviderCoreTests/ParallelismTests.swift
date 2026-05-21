import Foundation
import Testing
@testable import ProviderCore

// MARK: - Helpers

private func defaultInputs(
    operatorChoice: Parallelism = .auto,
    worldSize: Int = 2,
    modelHasTPVariant: Bool = true,
    attentionHeads: Int = 32,
    kvHeads: Int = 8,
    distributedGroupAvailable: Bool = true
) -> Parallelism.DecisionInputs {
    Parallelism.DecisionInputs(
        operatorChoice: operatorChoice,
        worldSize: worldSize,
        modelHasTPVariant: modelHasTPVariant,
        attentionHeads: attentionHeads,
        kvHeads: kvHeads,
        distributedGroupAvailable: distributedGroupAvailable
    )
}

// MARK: - Single-rank short-circuit

@Test func parallelismShortCircuitsToSingleWhenNoPeer() {
    let (chosen, reason) = Parallelism.decide(defaultInputs(worldSize: 1))
    #expect(chosen == .single)
    #expect(reason.contains("worldSize=1"))
}

@Test func parallelismShortCircuitsToSingleEvenIfOperatorAsksForTP() {
    // worldSize < 2 always wins; operator choice can't conjure a peer.
    let (chosen, _) = Parallelism.decide(
        defaultInputs(operatorChoice: .tp, worldSize: 1))
    #expect(chosen == .single)
}

// MARK: - Auto-decide path (the default)

@Test func parallelismAutoPicksTPWhenAllCapabilitiesAlign() {
    let (chosen, reason) = Parallelism.decide(defaultInputs())
    #expect(chosen == .tp)
    #expect(reason.contains("auto"))
}

@Test func parallelismAutoFallsBackToPPWhenDistributedGroupUnavailable() {
    // Capability gate failed (non-M5, or rdma_ctl disabled). PP can still
    // run because callPartial only needs ThunderboltLink, not jaccl.
    let (chosen, reason) = Parallelism.decide(
        defaultInputs(distributedGroupAvailable: false))
    #expect(chosen == .pp)
    #expect(reason.contains("DistributedGroup unavailable"))
}

@Test func parallelismAutoFallsBackToPPWhenModelHasNoTPVariant() {
    // Non-Llama model (e.g. Mistral, Qwen) until they get their own *TP
    // variants. PP works via callPartial.
    let (chosen, reason) = Parallelism.decide(
        defaultInputs(modelHasTPVariant: false))
    #expect(chosen == .pp)
    #expect(reason.contains("no TP variant"))
}

@Test func parallelismAutoFallsBackToPPWhenHeadsDontDivide() {
    // Odd head count can't shard across worldSize=2.
    let (chosen, reason) = Parallelism.decide(
        defaultInputs(attentionHeads: 33))
    #expect(chosen == .pp)
    #expect(reason.contains("divide evenly"))
}

@Test func parallelismAutoFallsBackToPPWhenKVHeadsDontDivide() {
    let (chosen, reason) = Parallelism.decide(
        defaultInputs(kvHeads: 7))
    #expect(chosen == .pp)
    #expect(reason.contains("divide evenly"))
}

// MARK: - Explicit operator overrides

@Test func parallelismHonorsExplicitPP() {
    let (chosen, reason) = Parallelism.decide(
        defaultInputs(operatorChoice: .pp))
    #expect(chosen == .pp)
    #expect(reason.contains("operator selected"))
}

@Test func parallelismHonorsExplicitSingle() {
    let (chosen, reason) = Parallelism.decide(
        defaultInputs(operatorChoice: .single))
    #expect(chosen == .single)
    #expect(reason.contains("operator selected"))
}

@Test func parallelismHonorsExplicitTPWhenAchievable() {
    let (chosen, reason) = Parallelism.decide(
        defaultInputs(operatorChoice: .tp))
    #expect(chosen == .tp)
    #expect(reason.contains("operator selected --parallelism tp"))
}

// MARK: - Explicit TP refuses to silently downgrade

@Test func parallelismExplicitTPFailsClosedWhenDistributedGroupUnavailable() {
    // Operator asked for TP. Capability gate failed. We refuse to silently
    // give them PP — that would mask a misconfiguration. Fall back to single
    // and surface the reason.
    let (chosen, reason) = Parallelism.decide(
        defaultInputs(operatorChoice: .tp, distributedGroupAvailable: false))
    #expect(chosen == .single)
    #expect(reason.contains("refusing to silently downgrade"))
}

@Test func parallelismExplicitTPFailsClosedWhenModelHasNoTPVariant() {
    let (chosen, reason) = Parallelism.decide(
        defaultInputs(operatorChoice: .tp, modelHasTPVariant: false))
    #expect(chosen == .single)
    #expect(reason.contains("refusing to silently downgrade"))
}

@Test func parallelismExplicitTPFailsClosedWhenHeadsDontDivide() {
    let (chosen, reason) = Parallelism.decide(
        defaultInputs(operatorChoice: .tp, attentionHeads: 33))
    #expect(chosen == .single)
    #expect(reason.contains("divide evenly"))
}

// MARK: - Divisibility helper

@Test func parallelismCanShardRequiresEvenDivision() {
    #expect(Parallelism.canShard(heads: 32, worldSize: 2) == true)
    #expect(Parallelism.canShard(heads: 33, worldSize: 2) == false)
    #expect(Parallelism.canShard(heads: 64, worldSize: 4) == true)
    #expect(Parallelism.canShard(heads: 0, worldSize: 2) == false)
    #expect(Parallelism.canShard(heads: 32, worldSize: 0) == false)
}
