import Foundation
import MLX
import MLXNN

/// File-private, live-observation-only permission for this one ordered load.
/// No caller can construct it from a fabricated CPU snapshot or planning receipt.
private final class QwenDenseStageLoadGate {
    let budget: QwenDenseStageLoadBudget
    private var next = 0, failed = false, finished = false
    private var observations: [QwenDenseStageLoadResourceDecision] = []

    init(budget: QwenDenseStageLoadBudget) throws {
        self.budget = budget
        let maximumBuffer = GPU.deviceInfo().maxBufferSize
        guard maximumBuffer > 0, budget.allocationBounds.allSatisfy({ $0 <= maximumBuffer }),
              budget.inertAllocationBound <= maximumBuffer else {
            throw ProbeError("Selected-stage allocator bounds exceed this device's maximum buffer size")
        }
        try observe()
    }

    func observe() throws {
        do {
            guard !failed, !finished, observations.count < 4096 else {
                throw ProbeError("Stage load gate is failed, consumed or exceeds its observation bound")
            }
            let os = try QwenDenseStageLoadResources.observeOS()
            let native = QwenDenseStageLoadResources.observeNative()
            let decision = try QwenDenseStageLoadPolicy.evaluate(budget: budget, ordinal: next,
                os: os, native: native, now: DispatchTime.now().uptimeNanoseconds)
            observations.append(decision)
        } catch { failed = true; throw error }
    }

    func beforeRead(_ entry: QwenStageActiveTensor) throws {
        do {
            guard !failed, !finished else { throw ProbeError("Stage load gate was already consumed or failed") }
            try budget.requireEntry(entry, ordinal: next)
            try observe()
            // A throw anywhere in the ensuing materializer poisons the whole
            // load. Advancing here accounts for its newly resident buffer at
            // the existing post-eval checks, before another read can begin.
            next += 1
        } catch { failed = true; throw error }
    }

    func finish() throws -> [QwenDenseStageLoadResourceDecision] {
        do {
            guard !failed, !finished, next == budget.active.count else {
                throw ProbeError("Stage load did not consume its complete selected tensor inventory")
            }
            try observe(); finished = true
            return observations
        } catch { failed = true; throw error }
    }

    func fail() { failed = true }
}

struct QwenDenseSelectedStageLoadResult {
    let receipt: QwenLayerStageLoadReceipt
    let budget: QwenDenseStageLoadBudget
    let resources: [QwenDenseStageLoadResourceDecision]
    let memory: [QwenStageMemoryObservation]
}

/// Exactly one selected model is loaded and retired inside this function.
/// The returned value contains CPU records only, never Loaded/model/arrays.
func materializeQwenDenseSelectedStage(_ prepared: QwenDenseConstructorSource,
    selection: QwenDenseStageLoadSelection, check: () throws -> Void
) throws -> QwenDenseSelectedStageLoadResult {
    let plan = selection.metadata.plan, index = selection.stageIndex
    guard prepared.profile.model == selection.metadata.specification.model,
          prepared.profile.configuration == selection.metadata.configuration,
          prepared.profile.manifest == selection.metadata.manifest,
          prepared.requirement.role == .sequentialPair,
          prepared.requirement.planFingerprint == plan.fingerprint else {
        throw ProbeError("Selected stage differs from the verified registered constructor source")
    }
    let selected = try QwenDenseStorageRequirement.derive(profile: prepared.profile, plan: plan,
        role: index == 0 ? .stage0 : .stage1)
    let other = try withRandomState(MLXRandom.RandomState(seed: 7)) {
        try inspectOtherQwenLayerStage(source: prepared.source, stage: plan.stages[1 - index], check: check)
    }
    try validateObservedQwenDenseStage(other, source: prepared.validation, profile: prepared.profile,
        requirement: prepared.requirement, plan: plan, stageIndex: 1 - index)
    weak var retired: Module?
    let result: QwenDenseSelectedStageLoadResult
    do {
        result = try autoreleasepool {
            try withRandomState(MLXRandom.RandomState(seed: 7)) {
                let value = try prepareQwenLayerStageModel(source: prepared.source, stage: plan.stages[index], check: check)
                retired = value.model
                try validateObservedQwenDenseStage(value.inventory, source: prepared.validation,
                    profile: prepared.profile, requirement: prepared.requirement, plan: plan, stageIndex: index)
                let inventories = [other, value.inventory].sorted { $0.summary.stageIndex < $1.summary.stageIndex }
                let commitment = try qwenLayerStageStorageCommitment(source: prepared.source,
                    originalConfiguration: selection.metadata.configuration, plan: plan, inventories: inventories)
                let activeBounds = try value.inventory.active.map { try Memory.allocationFootprintUpperBound(byteCount: $0.byteCount) }
                let inertBounds = try value.inventory.inert.flatMap(\.parameters).map { try Memory.allocationFootprintUpperBound(byteCount: $0.byteCount) }
                let budget = try QwenDenseStageLoadBudget.derive(profile: prepared.profile, plan: plan,
                    pair: prepared.requirement, selected: selected, source: prepared.validation, stageIndex: index,
                    active: value.inventory.active, inert: value.inventory.inert, summary: value.inventory.summary,
                    allocationBounds: activeBounds, inertAllocationBounds: inertBounds)
                try check()
                let gate = try QwenDenseStageLoadGate(budget: budget)
                do {
                    func checked() throws { try check(); try gate.observe(); try check() }
                    let before = QwenStageMemoryObservation("before_selected_stage_payload_load")
                    let loaded = try withoutActuallyEscaping(check) { borrowedCheck in
                        try materializeVerifiedQwenLayerStage(source: prepared.source, plan: plan,
                            stageIndex: index, model: value.model, inventory: value.inventory, commitment: commitment,
                            check: checked, beforeTensor: { entry in
                                try borrowedCheck(); try gate.beforeRead(entry); try borrowedCheck()
                            })
                    }
                    try check()
                    let observations = try gate.finish()
                    return QwenDenseSelectedStageLoadResult(receipt: loaded.receipt, budget: budget,
                        resources: observations, memory: [before, QwenStageMemoryObservation("selected_stage_payload_loaded")])
                } catch { gate.fail(); throw error }
            }
        }
    } catch {
        let primary = error
        guard retired == nil else { throw ProbeError("Selected stage load failed (\(primary)); model remained retained") }
        throw primary
    }
    guard retired == nil else { throw ProbeError("Selected loaded stage model remained retained") }
    try check()
    return result
}
