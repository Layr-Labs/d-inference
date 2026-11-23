import Testing
@testable import ProviderCore

private let gib: UInt64 = 1024 * 1024 * 1024
private let mib: UInt64 = 1024 * 1024

/// A 256 GB M5 Ultra serving GLM-5.3-Flash: 169.3 GiB resident with its
/// drafter and the default 5.5 GiB activation reserve.
private let physical = 256 * gib
private let glmWeights = 169 * gib + 300 * mib
private let reserve = 11 * gib / 2
/// macOS's default limit there (`ClusterGPUMemoryLimit`) and the production hosts' raised one.
private let defaultLimit = 228_065 * mib
private let raisedLimit = 245_760 * mib

private func capBudget(weights: UInt64 = glmWeights) -> UInt64 {
    UnifiedMemoryCap.kvBudgetBytes(
        physicalBytes: physical, residentWeightBytes: weights, activationReserveBytes: reserve,
        configReserveBytes: 0)
}

private func budget(
    _ types: [String?], retained: UInt64 = 0, limit: UInt64, weights: UInt64 = glmWeights
) -> UInt64 {
    GLM5NextGPULimitKVBudget.budgetBytes(
        capBudget(weights: weights), modelTypes: types, retainedGLMBytes: retained,
        residentWeightBytes: weights, activationReserveBytes: reserve, limit: .init(limitBytes: limit))
}

@Test func glmPlansItsKVWithinTheDefaultGPULimit() {
    // The cap alone plans weights + reserve + KV = 230.4 GiB, past the
    // 222.72 GiB the GPU may use.
    #expect(glmWeights + reserve + capBudget() > defaultLimit)
    let held = budget(["glm5_next"], limit: defaultLimit)
    #expect(glmWeights + reserve + held == defaultLimit)
    // Still more than one 262,144-token request needs (about 40.3 GiB).
    #expect(held > 47 * gib)
    for type in ["glm5_next_text", "glm5_next_mtp"] {
        #expect(budget([type], limit: defaultLimit) == held)
    }
}

@Test func theRaisedLimitKeepsTheCapBudget() {
    #expect(budget(["glm5_next"], limit: raisedLimit) == capBudget())
}

@Test func otherFamiliesAndAnUnreadLimitKeepTheCapBudget() {
    #expect(budget(["gemma4", nil], limit: defaultLimit) == capBudget())
    #expect(budget([], limit: defaultLimit) == capBudget())
    #expect(budget(["glm5_next"], limit: 0) == capBudget())
}

@Test func aCoResidentOrRetainedGLMHoldsTheWholeSet() {
    let weights = glmWeights + 6 * gib
    #expect(budget(["gemma4", "glm5_next"], limit: defaultLimit, weights: weights)
        == defaultLimit - weights - reserve)
    // A retained GLM owner still holds its wired memory with no slot left.
    #expect(budget(["gemma4"], retained: glmWeights, limit: defaultLimit) == defaultLimit - glmWeights - reserve)
}

@Test func aLimitBelowTheResidentSetLeavesNoKV() {
    #expect(budget(["glm5_next"], limit: glmWeights) == 0)
    #expect(GLM5NextGPULimitKVBudget.budgetBytes(
        .max, modelTypes: ["glm5_next"], retainedGLMBytes: 0, residentWeightBytes: .max,
        activationReserveBytes: 1, limit: .init(limitBytes: defaultLimit)) == 0)
}

@Test func theLimitIsReadOnlyForAGLMSet() {
    var reads = 0
    func limit() -> GLM5NextGPULimitKVBudget.GPULimit {
        reads += 1
        return .init(limitBytes: defaultLimit)
    }
    _ = GLM5NextGPULimitKVBudget.budgetBytes(
        capBudget(), modelTypes: ["gemma4"], retainedGLMBytes: 0, residentWeightBytes: glmWeights,
        activationReserveBytes: reserve, limit: limit())
    #expect(reads == 0)
    _ = GLM5NextGPULimitKVBudget.budgetBytes(
        capBudget(), modelTypes: ["glm5_next"], retainedGLMBytes: 0, residentWeightBytes: glmWeights,
        activationReserveBytes: reserve, limit: limit())
    #expect(reads == 1)
}

/// `DARKBLOOM_GLM_GPU_LIMIT_KV=0` keeps the cap's budget at the default limit, as 0.10.17 did; the LaunchAgent
/// forwards it.
@Test func theSwitchKeepsTheCapBudget() {
    let name = GLM5NextGPULimitKVBudget.environmentName
    #expect(GLM5NextGPULimitKVBudget.enabled(environment: [:]))
    for off in ["0", " off ", "False", "no"] { #expect(!GLM5NextGPULimitKVBudget.enabled(environment: [name: off])) }
    for on in ["1", "yes", ""] { #expect(GLM5NextGPULimitKVBudget.enabled(environment: [name: on])) }
    let off = GLM5NextGPULimitKVBudget.budgetBytes(
        capBudget(), modelTypes: ["glm5_next"], retainedGLMBytes: 0, residentWeightBytes: glmWeights,
        activationReserveBytes: reserve, limit: .init(limitBytes: defaultLimit), enabled: false)
    #expect(off == capBudget())
    #expect(budget(["glm5_next"], limit: defaultLimit) < off)
    #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(name))
}
