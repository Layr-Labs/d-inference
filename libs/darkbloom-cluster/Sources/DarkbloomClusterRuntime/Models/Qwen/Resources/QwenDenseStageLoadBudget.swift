import Foundation

/// Validated metadata and caller-supplied allocator bounds only. This type
/// never samples resources or grants loading permission.
struct QwenDenseStageLoadBudget: Encodable {
    let model: QwenRegisteredDenseModel, stageIndex: Int
    let profileFingerprint: String, planFingerprint: String
    let pairRequirementFingerprint: String, selectedRequirementFingerprint: String
    let activeMappingSHA256: String, active: [QwenStageActiveTensor]
    let allocationBounds: [Int], inertAllocationBound: Int
    let roundedResidentBytes: Int, largestHostTensorBytes: Int
    let resourceAdmissionPerformed = false, forwardExecutionAuthorized = false

    private init(profile: QwenRegisteredDenseModelProfile, plan: QwenLayerStagePlan,
        pair: QwenDenseStorageRequirement, selected: QwenDenseStorageRequirement,
        active: [QwenStageActiveTensor], summary: QwenStageStorageSummary,
        bounds: [Int], inert: Int, rounded: Int
    ) {
        model = profile.model; stageIndex = summary.stageIndex
        profileFingerprint = profile.fingerprint; planFingerprint = plan.fingerprint
        pairRequirementFingerprint = pair.fingerprint; selectedRequirementFingerprint = selected.fingerprint
        activeMappingSHA256 = summary.activeMappingSHA256; self.active = active
        allocationBounds = bounds; inertAllocationBound = inert
        roundedResidentBytes = rounded; largestHostTensorBytes = selected.largestHostTensorBytes
    }

    static func derive(profile: QwenRegisteredDenseModelProfile, plan: QwenLayerStagePlan,
        pair: QwenDenseStorageRequirement, selected: QwenDenseStorageRequirement,
        source: QwenDenseSourceReadPlan, stageIndex: Int, active: [QwenStageActiveTensor],
        inert: [QwenStageInertModule], summary: QwenStageStorageSummary,
        allocationBounds: [Int], inertAllocationBounds: [Int]
    ) throws -> Self {
        guard [0, 1].contains(stageIndex), pair.role == .sequentialPair,
              selected.role.stageIndex == stageIndex,
              plan.stages[0].sourceRange.upperBound == profile.geometry.layers / 2,
              try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: .sequentialPair).fingerprint == pair.fingerprint,
              try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: selected.role).fingerprint == selected.fingerprint else {
            throw ProbeError("Stage load budget uses a different profile, default Plan or selected role")
        }
        try QwenDenseObservedStageValidation.validateRegistered(source: source, profile: profile,
            requirement: pair, plan: plan, stageIndex: stageIndex, active: active, inert: inert, summary: summary)
        let placeholders = inert.flatMap(\.parameters)
        guard active.count == allocationBounds.count, placeholders.count == inertAllocationBounds.count,
              zip(active, allocationBounds).allSatisfy({ $0.1 >= $0.0.byteCount }),
              zip(placeholders, inertAllocationBounds).allSatisfy({ $0.1 >= $0.0.byteCount }),
              summary.loadedTensorBytes == selected.selectedActiveBytes,
              summary.inertTensorBytes == selected.selectedInertBytes,
              active.map(\.byteCount).max() == selected.largestHostTensorBytes else {
            throw ProbeError("Stage load allocator bounds or selected byte accounting differs")
        }
        let inertBound = try QwenLongPrefillCheckedBytes.sum(inertAllocationBounds)
        let rounded = try QwenLongPrefillCheckedBytes.sum(allocationBounds + [inertBound])
        return Self(profile: profile, plan: plan, pair: pair, selected: selected, active: active,
            summary: summary, bounds: allocationBounds, inert: inertBound, rounded: rounded)
    }

    func remainingAllocationBytes(after count: Int) throws -> Int {
        guard (0...active.count).contains(count) else { throw ProbeError("Invalid stage load progress") }
        // Inert parameters remain lazy, but retain their conservative allowance.
        return try QwenLongPrefillCheckedBytes.sum(Array(allocationBounds.dropFirst(count)) + [inertAllocationBound])
    }

    func requireEntry(_ entry: QwenStageActiveTensor, ordinal: Int) throws {
        guard active.indices.contains(ordinal) else { throw ProbeError("Stage load permission was consumed") }
        let expected = active[ordinal]
        guard entry.sourceName == expected.sourceName, entry.localName == expected.localName,
              entry.shape == expected.shape, entry.sourceDType == expected.sourceDType,
              entry.loadedDType == expected.loadedDType, entry.byteCount == expected.byteCount else {
            throw ProbeError("Stage load attempted a different or unordered tensor")
        }
    }
}
