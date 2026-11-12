import Foundation
import MLX
import MLXLMCommon
import MLXNN

struct QwenResidentLoadedStage {
    let loaded: LoadedQwenLayerStage
    let profile: QwenRegisteredDenseModelProfile
    let selectedRequirement: QwenDenseStorageRequirement
}

/// A private ordered-load gate for this separately admitted resident cut4|8|12|16
/// scope. The existing default-half-only StageLoadBudget policy is untouched.
private final class QwenResidentLoadGate {
    let active: [QwenStageActiveTensor], bounds: [Int], inert: Int, host: Int
    private let memory: QwenResidentMemoryRecorder?
    private var next = 0
    private var failed = false
    init(inventory: QwenStagePreparedInventory, memory: QwenResidentMemoryRecorder? = nil) throws {
        self.memory = memory
        active = inventory.active; host = active.map(\.byteCount).max() ?? 0
        bounds = try active.map { try Memory.allocationFootprintUpperBound(byteCount: $0.byteCount) }
        let inertBounds = try inventory.inert.flatMap(\.parameters).map {
            try Memory.allocationFootprintUpperBound(byteCount: $0.byteCount)
        }
        inert = try QwenLongPrefillCheckedBytes.sum(inertBounds)
        let maximum = GPU.deviceInfo().maxBufferSize
        guard !active.isEmpty, host > 0, maximum > 0,
              bounds.allSatisfy({ $0 > 0 && $0 <= maximum }),
              inertBounds.allSatisfy({ $0 > 0 && $0 <= maximum }) else {
            throw ProbeError("Resident selected buffers exceed actual device bounds")
        }
        try observe(phase: "initial")
    }
    func observe(phase: String = "materializer-check") throws {
        do {
            guard !failed else { throw ProbeError("Resident load gate was poisoned") }
            let remaining = try QwenLongPrefillCheckedBytes.sum(Array(bounds.dropFirst(next)) + [inert])
            let h = next < active.count ? host : 0
            let scratch = h == 0 ? 0 : CheckpointAlignedReadPlan.maximumScratchAllocationBytes
            let required = max(QwenDenseStageLoadPolicy.minimumActualFreeBytes,
                try QwenLongPrefillCheckedBytes.sum([remaining, h, h, scratch, QwenDenseStageLoadPolicy.loadingHeadroomBytes,
                    memory?.hostReservationBytes ?? 0]))
            let activeBytes = Memory.activeMemory
            let cacheBytes = Memory.cacheMemory
            let allocator = try QwenLongPrefillCheckedBytes.sum([activeBytes, cacheBytes,
                remaining, h, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
            let observer = try memory?.observer(phase == "finish" ? .loadComplete : .load,
                authorizedTensorCount: next, selectedTensorCount: active.count)
            var memoryPages: QwenResidentMemoryPages?
            let os = try QwenDenseStageLoadResources.requireInitial(
                memoryPages: observer == nil ? nil : { memoryPages = $0 })
            let freeAdmitted = os.actualFreeBytes >= required
            // Preserve the original short-circuit: no allocator-limit read after a free-memory refusal.
            let allocatorLimit: Int? = freeAdmitted ? Memory.memoryLimit : nil
            guard freeAdmitted, let allocatorLimit, allocatorLimit >= allocator else {
                throw ProbeError("Resident load exceeds current actual-free or allocator policy"
                    + "; phase=\(phase); readAdmitted=\(next)/\(active.count)"
                    + "; actualFreeBytes=\(os.actualFreeBytes); requiredFreeBytes=\(required)"
                    + "; remainingBoundBytes=\(remaining); hostTensorBytes=\(h); scratchBytes=\(scratch)"
                    + "; activeBytes=\(activeBytes); cacheBytes=\(cacheBytes)"
                    + "; allocatorRequiredBytes=\(allocator)"
                    + "; allocatorLimitBytes=\(allocatorLimit.map(String.init) ?? "not-read")")
            }
            if let observer, let memoryPages { try observer(os, memoryPages, required, allocator) }
        } catch { failed = true; throw error }
    }
    func beforeRead(_ entry: QwenStageActiveTensor) throws {
        guard active.indices.contains(next), active[next].sourceName == entry.sourceName,
              active[next].localName == entry.localName, active[next].shape == entry.shape,
              active[next].sourceDType == entry.sourceDType, active[next].loadedDType == entry.loadedDType,
              active[next].byteCount == entry.byteCount else {
            failed = true; throw ProbeError("Resident load changed its admitted ordered tensor inventory")
        }
        try observe(phase: "before-read"); next += 1
    }
    func finish() throws {
        guard next == active.count else { failed = true; throw ProbeError("Resident load incomplete") }
        try observe(phase: "finish")
    }
}

/// The sole internal model-returning seam; public facade stores this privately.
/// All actual source, both compact inventories and allocation limits are checked
/// before entering the unchanged selected-tensor materializer.
func loadQwenResidentStage(_ admission: QwenResidentAdmission,
                          memory: QwenResidentMemoryRecorder? = nil, check: () throws -> Void) throws -> QwenResidentLoadedStage {
    let prepared = try prepareQwenResidentSource(admission, check: check)
    let plan = admission.plan, index = admission.configuration.rank
    let other = try withRandomState(MLXRandom.RandomState(seed: 7)) {
        try inspectOtherQwenLayerStage(source: prepared.source, stage: plan.stages[1 - index], check: check)
    }
    try QwenDenseObservedStageValidation.validateRegistered(source: prepared.validation, profile: prepared.profile,
        requirement: prepared.pairRequirement, plan: plan, stageIndex: 1 - index,
        active: other.active, inert: other.inert, summary: other.summary)
    return try autoreleasepool {
        try withRandomState(MLXRandom.RandomState(seed: 7)) {
            let value = try prepareQwenLayerStageModel(source: prepared.source, stage: plan.stages[index], check: check)
            try QwenDenseObservedStageValidation.validateRegistered(source: prepared.validation, profile: prepared.profile,
                requirement: prepared.pairRequirement, plan: plan, stageIndex: index,
                active: value.inventory.active, inert: value.inventory.inert, summary: value.inventory.summary)
            let commitment = try qwenLayerStageStorageCommitment(source: prepared.source,
                originalConfiguration: admission.configBytes, plan: plan,
                inventories: [other, value.inventory].sorted { $0.summary.stageIndex < $1.summary.stageIndex })
            let selected = try QwenDenseStorageRequirement.derive(profile: prepared.profile,
                plan: plan, role: index == 0 ? .stage0 : .stage1)
            let gate = try QwenResidentLoadGate(inventory: value.inventory, memory: memory)
            let loaded = try withoutActuallyEscaping(check) { borrowedCheck in
                try materializeVerifiedQwenLayerStage(source: prepared.source, plan: plan,
                    stageIndex: index, model: value.model, inventory: value.inventory, commitment: commitment,
                    check: { try borrowedCheck(); try gate.observe(); try borrowedCheck() },
                    beforeTensor: { try borrowedCheck(); try gate.beforeRead($0); try borrowedCheck() })
            }
            try gate.finish(); try check()
            return .init(loaded: loaded, profile: prepared.profile, selectedRequirement: selected)
        }
    }
}
