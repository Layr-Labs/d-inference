import Foundation

/// Pure named operational allowance for one exact short history. This is not a
/// resource permit, full peak bound, or statement of model/hardware eligibility.
struct QwenDenseShortRequestLedger: Encodable {
    let model: QwenRegisteredDenseModel
    let modelProfileFingerprint: String, planFingerprint: String, recordedRequestFingerprint: String
    let configurationSHA256: String, manifestSHA256: String, artifactAggregateSHA256: String
    let canonicalInventorySHA256: String
    let scope: QwenDenseShortLedgerScope
    let geometry: QwenLongPrefillBudgetGeometry
    let stateOwners: [QwenDenseShortStateOwner]
    let namedStateBudget: QwenLongPrefillTensorBudget
    let nativeAllowances: [QwenDenseShortBufferAllowance]
    let cpuEvidence: QwenDenseShortCPUEvidenceAllowance
    let nativeCapacityStateBytes: Int, nativeAllowanceBytes: Int, fusionReplacementLogicalBytes: Int
    let forwardReserveBytes: Int, fingerprint: String
    let promptCount = 3, chunkSize = 2, outputCount = 2, teacherCount = 1, maximumTokens = 5
    let committedFrontiers = [2, 3, 4]
    let runtimeExecutionAuthorized = false, allocatorProvenanceIndependentlyVerified = false
    let isWholeProcessMemoryBound = false, unknownNativeScratchIncluded = false
    let objectAndSerializationOverheadIncluded = false
    let weightsAndLoadHostCopiesIncluded = false

    private init(profile: QwenRegisteredDenseModelProfile, plan: QwenLayerStagePlan,
                 request: QwenLayerStageRecordedRequest, scope: QwenDenseShortLedgerScope,
                 owners: [QwenDenseShortStateOwner], budget: QwenLongPrefillTensorBudget,
                 buffers: [QwenDenseShortBufferAllowance], cpu: QwenDenseShortCPUEvidenceAllowance,
                 fusion: Int) throws {
        let sum = QwenLongPrefillCheckedBytes.sum
        self.model = profile.model; self.modelProfileFingerprint = profile.fingerprint
        self.planFingerprint = plan.fingerprint; self.recordedRequestFingerprint = request.fingerprint
        self.configurationSHA256 = profile.configurationSHA256; self.manifestSHA256 = profile.manifestSHA256
        self.artifactAggregateSHA256 = profile.artifactAggregateSHA256
        self.canonicalInventorySHA256 = profile.canonicalInventorySHA256
        self.scope = scope; self.geometry = profile.geometry; self.stateOwners = owners
        self.namedStateBudget = budget; self.nativeAllowances = buffers; self.cpuEvidence = cpu
        self.nativeCapacityStateBytes = try sum(owners.map(\.nativeCapacityStateBytes))
        self.nativeAllowanceBytes = try sum(buffers.map(\.allocationBoundBytes))
        self.fusionReplacementLogicalBytes = fusion
        self.forwardReserveBytes = try sum([nativeAllowanceBytes, cpu.logicalBytes])
        self.fingerprint = QwenDenseProfileIdentity.fingerprint([
            "qwen-dense-short-request-ledger-v1", profile.fingerprint, plan.fingerprint,
            request.fingerprint, scope.rawValue, "tokens=3/2/2/teacher1/capacity5",
            try QwenDenseProfileIdentity.encodedFingerprint(owners),
            try QwenDenseProfileIdentity.encodedFingerprint(budget),
            try QwenDenseProfileIdentity.encodedFingerprint(buffers),
            try QwenDenseProfileIdentity.encodedFingerprint(cpu), "fusion=\(fusion)",
            "reserve=\(forwardReserveBytes)", "executionAuthorized=false", "wholePeak=false",
        ])
    }

    static func derive(profile: QwenRegisteredDenseModelProfile, plan: QwenLayerStagePlan,
                       request: QwenLayerStageRecordedRequest, scope: QwenDenseShortLedgerScope,
                       allocationFootprintUpperBound bound: (Int) throws -> Int) throws -> Self {
        // Closed metadata/history checks precede the first allocator callback.
        let expectedPlan = try profile.makePlanningPlan()
        guard plan.originalConfiguration == profile.configuration,
              plan.fingerprint == expectedPlan.fingerprint,
              plan.stages.map(\.fingerprint) == expectedPlan.stages.map(\.fingerprint),
              plan.stages.map(\.constructionConfiguration) == expectedPlan.stages.map(\.constructionConfiguration),
              request.request.promptCount == 3, request.request.chunkSize == 2,
              request.request.outputCount == 2, request.teacherTokenIDs.count == 1,
              request.vocabularySize == profile.vocabularySize,
              request.steps.map(\.committedTokens) == [2, 3, 4],
              request.steps.map({ $0.frame.tokenCount }) == [2, 1, 1],
              request.steps.map(\.expectsLogits) == [false, true, true] else {
            throw QwenDenseProfileError("Short ledger requires the exact registered default Plan and 3/2/2 history")
        }
        let replay = try QwenLayerStageRecordedRequest(request: request.request,
            vocabularySize: profile.vocabularySize, prompt: request.promptTokenIDs, teacher: request.teacherTokenIDs)
        guard replay.fingerprint == request.fingerprint,
              try QwenDenseProfileIdentity.encodedFingerprint(replay.steps) ==
                QwenDenseProfileIdentity.encodedFingerprint(request.steps) else {
            throw QwenDenseProfileError("Short ledger history differs from the actual recorded schedule")
        }
        let g = profile.geometry, product = QwenLongPrefillCheckedBytes.product
        let sum = QwenLongPrefillCheckedBytes.sum
        let budget = try QwenLongPrefillTensorBudget.estimate(geometry: g, maximumTokens: 5, chunkSize: 2)
        guard budget.conservativeStateAndBoundaryBytes <= 512 * 1024 * 1024 else {
            throw QwenDenseProfileError("Short named state allowance exceeds the existing 512 MiB comparison ceiling")
        }
        // Only weight/fusion identity is consumed from this explicitly 8K type;
        // none of its long request, state, or partial-ledger values is reused.
        let storage = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan,
            role: scope == .fullReference ? .fullReference : .sequentialPair)
        let owners: [QwenDenseShortStateOwner]
        if scope == .fullReference {
            owners = [try QwenDenseShortStateLedger.owner(geometry: g, name: "full", lower: 0, upper: g.layers)]
        } else {
            owners = try plan.stages.map { stage in
                try QwenDenseShortStateLedger.owner(geometry: g, name: "stage\(stage.index)",
                    lower: stage.sourceRange.lowerBound, upper: stage.sourceRange.upperBound)
            }
        }
        var builder = QwenDenseShortAllowanceBuilder()
        for owner in owners {
            try QwenDenseShortStateLedger.appendAllowances(owner: owner, geometry: g, builder: &builder, bound: bound)
        }
        guard try sum(builder.buffers.map(\.logicalBytes)) ==
            sum([budget.threeRecurrentGenerationsBytes, budget.allKVCapacityAndOffsetsBytes]) else {
            throw QwenDenseProfileError("Short per-array state allowance differs from the checked named formula")
        }
        try QwenDenseShortFusionLedger.append(profile: profile, plan: plan, scope: scope,
            expectedBytes: storage.fusionReplacementBytes, builder: &builder, bound: bound)
        try QwenDenseShortWorkspaceLedger.append(profile: profile, owners: owners, scope: scope,
            builder: &builder, bound: bound)
        let nativeRow = try product([profile.vocabularySize, 2]), floatRow = try product([profile.vocabularySize, 4])
        let pair = scope == .sequentialStagePair
        let baselineNative = try product([2, nativeRow]), baselineFloat = try product([2, floatRow])
        let candidateFloat = pair ? try product([2, floatRow]) : 0
        let candidateNative = pair ? nativeRow : 0
        let boundaryCopies = pair ? budget.twoBoundaryArraysBytes : 0
        let cpu = QwenDenseShortCPUEvidenceAllowance(baselineNativeRowBytes: baselineNative,
            baselineFloatRowBytes: baselineFloat, candidateFloatRowBytes: candidateFloat,
            transientCandidateNativeRowBytes: candidateNative,
            largestSingleStateCopyBytes: budget.largestSingleHostStateComponentBytes,
            boundaryCopyBytes: boundaryCopies,
            logicalBytes: try sum([baselineNative, baselineFloat, candidateFloat, candidateNative,
                                  budget.largestSingleHostStateComponentBytes, boundaryCopies]))
        return try Self(profile: profile, plan: plan, request: request, scope: scope, owners: owners,
            budget: budget, buffers: builder.buffers, cpu: cpu, fusion: storage.fusionReplacementBytes)
    }
}
