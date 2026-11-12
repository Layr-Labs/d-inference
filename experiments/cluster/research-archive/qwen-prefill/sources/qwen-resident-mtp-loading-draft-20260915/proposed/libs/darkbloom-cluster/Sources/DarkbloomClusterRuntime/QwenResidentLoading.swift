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
    let additional: QwenResidentMTPLoadResources?
    private var next = 0
    private var failed = false
    init(inventory: QwenStagePreparedInventory, additional: QwenResidentMTPLoadResources? = nil) throws {
        self.additional = additional
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
        try observe()
    }
    func observe() throws {
        do {
            guard !failed else { throw ProbeError("Resident load gate was poisoned") }
            let remaining = try QwenLongPrefillCheckedBytes.sum(Array(bounds.dropFirst(next))
                + [inert, additional?.reservedTensorBytes ?? 0])
            let h = max(next < active.count ? host : 0, additional?.largestHostTensorBytes ?? 0)
            let scratch = h == 0 ? 0 : CheckpointAlignedReadPlan.maximumScratchAllocationBytes
            let required = max(QwenDenseStageLoadPolicy.minimumActualFreeBytes,
                try QwenLongPrefillCheckedBytes.sum([remaining, h, h, scratch, QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
            let allocator = try QwenLongPrefillCheckedBytes.sum([Memory.activeMemory, Memory.cacheMemory,
                remaining, h, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
            let os = try QwenDenseStageLoadResources.requireInitial()
            guard os.actualFreeBytes >= required, Memory.memoryLimit >= allocator else {
                throw ProbeError("Resident load exceeds current actual-free or allocator policy")
            }
        } catch { failed = true; throw error }
    }
    func beforeRead(_ entry: QwenStageActiveTensor) throws {
        guard active.indices.contains(next), active[next].sourceName == entry.sourceName,
              active[next].localName == entry.localName, active[next].shape == entry.shape,
              active[next].sourceDType == entry.sourceDType, active[next].loadedDType == entry.loadedDType,
              active[next].byteCount == entry.byteCount else {
            failed = true; throw ProbeError("Resident load changed its admitted ordered tensor inventory")
        }
        try observe(); next += 1
    }
    func finish() throws {
        guard next == active.count else { failed = true; throw ProbeError("Resident load incomplete") }
        try observe()
    }
}

/// The sole internal model-returning seam; public facade stores this privately.
/// All actual source, both compact inventories and allocation limits are checked
/// before entering the unchanged selected-tensor materializer.
func loadQwenResidentStage(_ admission: QwenResidentAdmission,
                          check: () throws -> Void) throws -> QwenResidentLoadedStage {
    let prepared = try prepareQwenResidentSource(admission, check: check)
    return try loadPreparedQwenResidentStage(admission, prepared: prepared, check: check)
}

/// Same selected-stage body, with descriptor ownership supplied by the caller.
/// The ordinary entry above retains its original source/read order and receipts.
func loadPreparedQwenResidentStage(_ admission: QwenResidentAdmission,
    prepared: QwenResidentSource, additional: QwenResidentMTPLoadResources? = nil,
    check: () throws -> Void
) throws -> QwenResidentLoadedStage {
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
            let gate = try QwenResidentLoadGate(inventory: value.inventory, additional: additional)
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
