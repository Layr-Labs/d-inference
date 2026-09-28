import Foundation

struct QwenDenseShortPairLoadProgress: Encodable, Equatable {
    let completedStages: Int, tensorOrdinal: Int
}

/// Composes the two existing exact stage budgets with one short pair reserve.
/// Pure metadata; neither this value nor a fabricated resource decision grants a read.
struct QwenDenseShortPairLoadBudget: Encodable {
    let model: QwenRegisteredDenseModel
    let profileFingerprint: String, planFingerprint: String, pairRequirementFingerprint: String
    let referenceAdmissionFingerprint: String, recordedRequestFingerprint: String
    let promptSHA256: String, teacherSHA256: String, shortLedgerFingerprint: String
    let stages: [QwenDenseStageLoadBudget]
    let roundedResidentBytes: Int, largestHostTensorBytes: Int, forwardReserveBytes: Int
    let fingerprint: String
    let role = "sequentialStagePair", maximumTokens = 5
    let resourceAdmissionPerformed = false, forwardExecuted = false

    private init(profile: QwenRegisteredDenseModelProfile, plan: QwenLayerStagePlan,
        requirement: QwenDenseStorageRequirement, admission: QwenDenseShortReferenceAdmission,
        ledger: QwenDenseShortRequestLedger, stages: [QwenDenseStageLoadBudget], rounded: Int
    ) throws {
        model = profile.model; profileFingerprint = profile.fingerprint; planFingerprint = plan.fingerprint
        pairRequirementFingerprint = requirement.fingerprint
        referenceAdmissionFingerprint = admission.fingerprint; recordedRequestFingerprint = admission.request.fingerprint
        promptSHA256 = admission.promptSHA256; teacherSHA256 = admission.teacherSHA256
        shortLedgerFingerprint = ledger.fingerprint; self.stages = stages
        roundedResidentBytes = rounded; largestHostTensorBytes = requirement.largestHostTensorBytes
        forwardReserveBytes = ledger.forwardReserveBytes
        fingerprint = QwenDenseProfileIdentity.fingerprint([
            "registered-dense-short-pair-load-budget-v1", profile.fingerprint, plan.fingerprint,
            requirement.fingerprint, admission.fingerprint, ledger.fingerprint,
            try QwenDenseProfileIdentity.encodedFingerprint(stages), "reserve=\(ledger.forwardReserveBytes)",
        ])
    }

    static func derive(profile: QwenRegisteredDenseModelProfile, plan: QwenLayerStagePlan,
        requirement: QwenDenseStorageRequirement, source: QwenDenseSourceReadPlan,
        admission: QwenDenseShortReferenceAdmission, ledger: QwenDenseShortRequestLedger,
        stages: [QwenDenseStageLoadBudget]
    ) throws -> Self {
        let pair = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: .sequentialPair)
        guard requirement.role == .sequentialPair, requirement.fingerprint == pair.fingerprint,
              source.registeredProfileFingerprint == profile.fingerprint,
              source.registeredRequirementFingerprint == pair.fingerprint,
              source.tensors.map(\.canonical) == profile.canonicalTensors,
              admission.metadata.specification.model == profile.model,
              admission.metadata.configuration == profile.configuration,
              admission.metadata.manifest == profile.manifest, admission.metadata.plan.fingerprint == plan.fingerprint,
              plan.stages[0].sourceRange.upperBound == profile.geometry.layers / 2,
              ledger.scope == .sequentialStagePair, ledger.model == profile.model,
              ledger.modelProfileFingerprint == profile.fingerprint, ledger.planFingerprint == plan.fingerprint,
              ledger.recordedRequestFingerprint == admission.request.fingerprint,
              ledger.maximumTokens == 5, ledger.promptCount == 3, ledger.chunkSize == 2,
              ledger.outputCount == 2, ledger.teacherCount == 1, ledger.committedFrontiers == [2, 3, 4],
              ledger.forwardReserveBytes > 0, stages.map(\.stageIndex) == [0, 1] else {
            throw ProbeError("Short pair budget differs in source, role, default Plan or recorded history")
        }
        for index in [0, 1] {
            let stage = stages[index]
            let selected = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan,
                role: index == 0 ? .stage0 : .stage1)
            guard stage.model == profile.model, stage.profileFingerprint == profile.fingerprint,
                  stage.planFingerprint == plan.fingerprint, stage.pairRequirementFingerprint == pair.fingerprint,
                  stage.selectedRequirementFingerprint == selected.fingerprint else {
                throw ProbeError("Short pair contains a stage from a different source or role")
            }
        }
        let names = stages.flatMap { $0.active.map(\.sourceName) }
        guard names.count == profile.canonicalTensors.count,
              Set(names).count == names.count, Set(names) == Set(profile.canonicalTensors.map(\.name)),
              try QwenLongPrefillCheckedBytes.sum(stages.flatMap { $0.active.map(\.byteCount) }) == profile.sourceTensorBytes else {
            throw ProbeError("Short pair stages do not conserve the exact full source ownership")
        }
        return try .init(profile: profile, plan: plan, requirement: pair, admission: admission,
            ledger: ledger, stages: stages, rounded: QwenLongPrefillCheckedBytes.sum(stages.map(\.roundedResidentBytes)))
    }

    func validate(_ progress: QwenDenseShortPairLoadProgress) throws {
        guard (0...2).contains(progress.completedStages), progress.tensorOrdinal >= 0 else {
            throw ProbeError("Short pair has invalid completed-stage or tensor progress")
        }
        if progress.completedStages == 2 {
            guard progress.tensorOrdinal == 0 else { throw ProbeError("Completed short pair retains tensor progress") }
        } else {
            guard progress.tensorOrdinal <= stages[progress.completedStages].active.count else {
                throw ProbeError("Short pair progress exceeds its current stage inventory")
            }
        }
    }

    func remainingAllocationBytes(_ progress: QwenDenseShortPairLoadProgress) throws -> Int {
        try validate(progress)
        let completedInert = try QwenLongPrefillCheckedBytes.sum(
            stages.prefix(progress.completedStages).map(\.inertAllocationBound))
        guard progress.completedStages < 2 else { return completedInert }
        let index = progress.completedStages
        let current = try stages[index].remainingAllocationBytes(after: progress.tensorOrdinal)
        // Stage materialization evaluates only active tensors. Inert parameters
        // may remain lazy, so every inert allowance survives stage completion.
        // Observed allocator active/cache separately charge loaded active buffers.
        return try QwenLongPrefillCheckedBytes.sum([completedInert, current]
            + stages.dropFirst(index + 1).map(\.roundedResidentBytes))
    }

    func hostAllowanceBytes(_ progress: QwenDenseShortPairLoadProgress) throws -> Int {
        try validate(progress)
        if progress.completedStages == 2 { return 0 }
        if progress.completedStages == 1 && progress.tensorOrdinal == stages[1].active.count { return 0 }
        return largestHostTensorBytes
    }

    func requireEntry(_ entry: QwenStageActiveTensor, stageIndex: Int,
        progress: QwenDenseShortPairLoadProgress
    ) throws {
        try validate(progress)
        guard stages.indices.contains(stageIndex), stageIndex == progress.completedStages else {
            throw ProbeError("Short pair attempted an out-of-order stage read")
        }
        try stages[stageIndex].requireEntry(entry, ordinal: progress.tensorOrdinal)
    }

    func requireCompletion(stageIndex: Int, progress: QwenDenseShortPairLoadProgress) throws {
        try validate(progress)
        guard stages.indices.contains(stageIndex), stageIndex == progress.completedStages,
              progress.tensorOrdinal == stages[stageIndex].active.count else {
            throw ProbeError("Short pair stage completion precedes its exact full tensor inventory")
        }
    }
}
