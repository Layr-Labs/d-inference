import Foundation
import MLX
import MLXNN

/// Private live permission for two ordered stages; caller-supplied scalar
/// observations and budgets cannot instantiate or complete this owner state.
private final class QwenDenseShortPairLoadGate {
    let budget: QwenDenseShortPairLoadBudget
    private var completed = 0, next = 0, failed = false, finished = false
    private var observations: [QwenDenseShortPairResourceDecision] = []
    private var progress: QwenDenseShortPairLoadProgress { .init(completedStages: completed, tensorOrdinal: next) }

    init(budget: QwenDenseShortPairLoadBudget) throws {
        self.budget = budget
        let maximum = GPU.deviceInfo().maxBufferSize
        guard maximum > 0, budget.stages.allSatisfy({
            $0.allocationBounds.allSatisfy { $0 <= maximum } && $0.inertAllocationBound <= maximum
        }) else { throw ProbeError("Short pair exceeds this device's maximum buffer") }
        try observe()
    }

    func observe() throws {
        do {
            guard !failed, !finished, observations.count < 8192 else {
                throw ProbeError("Short pair gate is failed, consumed or exceeds its observation limit")
            }
            let os = try QwenDenseStageLoadResources.observeOS()
            let native = QwenDenseStageLoadResources.observeNative()
            observations.append(try QwenDenseShortPairResourcePolicy.evaluate(budget: budget, progress: progress,
                os: os, native: native, now: DispatchTime.now().uptimeNanoseconds))
        } catch { failed = true; throw error }
    }

    func beforeRead(_ entry: QwenStageActiveTensor, stageIndex: Int) throws {
        do {
            guard !failed, !finished else { throw ProbeError("Short pair read follows failure or completion") }
            try budget.requireEntry(entry, stageIndex: stageIndex, progress: progress)
            try observe(); next += 1
        } catch { failed = true; throw error }
    }

    /// Called after the unchanged materializer's active eval/fences and final
    /// freeze/layout checks. Inert allowances remain pending even after this;
    /// neither freeze nor parameter introspection proves their materialization.
    func completeStage(_ stageIndex: Int) throws {
        do {
            guard !failed, !finished else { throw ProbeError("Short pair stage follows failure or completion") }
            try budget.requireCompletion(stageIndex: stageIndex, progress: progress)
            try observe(); completed += 1; next = 0; try observe()
        } catch { failed = true; throw error }
    }

    func finish() throws -> [QwenDenseShortPairResourceDecision] {
        do {
            guard !failed, !finished, completed == 2, next == 0 else {
                throw ProbeError("Short pair did not finish both exact stage inventories")
            }
            try observe(); finished = true
            return observations
        } catch { failed = true; throw error }
    }
    func fail() { failed = true }
}

/// Both models are private to the autorelease scope and remain retained through
/// the whole pair load. A later recorder/comparator continuation must stay here;
/// this API currently returns loading-only CPU evidence after model retirement.
func materializeQwenDenseShortPair(_ prepared: QwenDenseConstructorSource,
    admission: QwenDenseShortReferenceAdmission, check: () throws -> Void
) throws -> QwenDenseShortPairLoadResult {
    let metadata = admission.metadata, plan = metadata.plan
    guard prepared.profile.model == metadata.specification.model,
          prepared.profile.configuration == metadata.configuration,
          prepared.profile.manifest == metadata.manifest,
          prepared.requirement.role == .sequentialPair,
          prepared.requirement.planFingerprint == plan.fingerprint else {
        throw ProbeError("Short pair differs from its verified registered source and default Plan")
    }
    weak var retired0: Module?
    weak var retired1: Module?
    let result: QwenDenseShortPairLoadResult
    do {
        result = try autoreleasepool {
            let values = try plan.stages.map { stage in
                let value = try withRandomState(MLXRandom.RandomState(seed: 7)) {
                    try prepareQwenLayerStageModel(source: prepared.source, stage: stage, check: check)
                }
                if stage.index == 0 { retired0 = value.model } else { retired1 = value.model }
                try validateObservedQwenDenseStage(value.inventory, source: prepared.validation,
                    profile: prepared.profile, requirement: prepared.requirement, plan: plan, stageIndex: stage.index)
                return value
            }
            let commitment = try qwenLayerStageStorageCommitment(source: prepared.source,
                originalConfiguration: metadata.configuration, plan: plan, inventories: values.map { $0.inventory })
            let maximum = GPU.deviceInfo().maxBufferSize
            guard maximum > 0 else { throw ProbeError("Short pair device has no valid maximum buffer") }
            func bound(_ bytes: Int) throws -> Int {
                let result = try Memory.allocationFootprintUpperBound(byteCount: bytes)
                guard result <= maximum else { throw ProbeError("Short pair named allocation exceeds device maximum") }
                return result
            }
            let stages = try values.enumerated().map { index, value in
                let selected = try QwenDenseStorageRequirement.derive(profile: prepared.profile, plan: plan,
                    role: index == 0 ? .stage0 : .stage1)
                return try QwenDenseStageLoadBudget.derive(profile: prepared.profile, plan: plan,
                    pair: prepared.requirement, selected: selected, source: prepared.validation, stageIndex: index,
                    active: value.inventory.active, inert: value.inventory.inert, summary: value.inventory.summary,
                    allocationBounds: value.inventory.active.map { try bound($0.byteCount) },
                    inertAllocationBounds: value.inventory.inert.flatMap(\.parameters).map { try bound($0.byteCount) })
            }
            let ledger = try QwenDenseShortRequestLedger.derive(profile: prepared.profile, plan: plan,
                request: admission.request, scope: .sequentialStagePair, allocationFootprintUpperBound: bound)
            let budget = try QwenDenseShortPairLoadBudget.derive(profile: prepared.profile, plan: plan,
                requirement: prepared.requirement, source: prepared.validation, admission: admission, ledger: ledger, stages: stages)
            try check()
            let gate = try QwenDenseShortPairLoadGate(budget: budget)
            do {
                // Explicitly retain stage 0's real model throughout stage 1's
                // loading and resource samples, even after its receipt is copied.
                return try withExtendedLifetime(values) {
                    var loads: [QwenLayerStageLoadReceipt] = []
                    var memory = [QwenStageMemoryObservation("before_short_pair_payload_load")]
                    for index in [0, 1] {
                        func checked() throws { try check(); try gate.observe(); try check() }
                        let loaded = try withoutActuallyEscaping(check) { borrowedCheck in
                            try materializeVerifiedQwenLayerStage(source: prepared.source, plan: plan,
                                stageIndex: index, model: values[index].model, inventory: values[index].inventory,
                                commitment: commitment, check: checked, beforeTensor: { entry in
                                    try borrowedCheck(); try gate.beforeRead(entry, stageIndex: index); try borrowedCheck()
                                })
                        }
                        try check(); try gate.completeStage(index); try check()
                        loads.append(loaded.receipt)
                        memory.append(QwenStageMemoryObservation("short_pair_stage\(index)_payload_loaded"))
                    }
                    try prepared.source.prepared.checkpoint.checkUnchanged(); try check()
                    let observations = try gate.finish()
                    return QwenDenseShortPairLoadResult(loads: loads, budget: budget, resources: observations, memory: memory)
                }
            } catch { gate.fail(); throw error }
        }
    } catch {
        let primary = error
        guard retired0 == nil, retired1 == nil else {
            throw ProbeError("Short pair load failed (\(primary)); a stage model remained retained")
        }
        throw primary
    }
    guard retired0 == nil, retired1 == nil else { throw ProbeError("Short pair retained a loaded stage model") }
    try check()
    return result
}
