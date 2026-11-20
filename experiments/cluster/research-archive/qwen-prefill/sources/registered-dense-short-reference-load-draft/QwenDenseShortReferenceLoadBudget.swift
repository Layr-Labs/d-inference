import Foundation

/// Exact full-source metadata plus caller-provided allocation bounds. Only a
/// private owner that samples live resources can permit the ensuing reads.
struct QwenDenseShortReferenceLoadBudget: Encodable {
    let model: QwenRegisteredDenseModel
    let profileFingerprint: String, planFingerprint: String, fullRequirementFingerprint: String
    let admissionFingerprint: String, recordedRequestFingerprint: String
    let promptSHA256: String, teacherSHA256: String, shortLedgerFingerprint: String
    let tensors: [QwenDenseCanonicalTensor], allocationBounds: [Int]
    let expectedLoadedLayoutSHA256: String
    let roundedResidentBytes: Int, largestHostTensorBytes: Int, forwardReserveBytes: Int
    let role = "fullReference", promptCount = 3, chunkSize = 2, outputCount = 2, teacherCount = 1
    let maximumTokens = 5, forwardExecuted = false, resourceAdmissionPerformed = false

    private init(profile: QwenRegisteredDenseModelProfile, requirement: QwenDenseStorageRequirement,
        source: QwenDenseSourceReadPlan, admission: QwenDenseShortReferenceAdmission,
        ledger: QwenDenseShortRequestLedger, allocationBounds: [Int], rounded: Int
    ) {
        model = profile.model; profileFingerprint = profile.fingerprint
        planFingerprint = requirement.planFingerprint; fullRequirementFingerprint = requirement.fingerprint
        admissionFingerprint = admission.fingerprint; recordedRequestFingerprint = admission.request.fingerprint
        promptSHA256 = admission.promptSHA256; teacherSHA256 = admission.teacherSHA256
        shortLedgerFingerprint = ledger.fingerprint; tensors = source.tensors.map(\.canonical)
        self.allocationBounds = allocationBounds; expectedLoadedLayoutSHA256 = source.expectedLayoutSHA256
        roundedResidentBytes = rounded; largestHostTensorBytes = source.largestSourceBytes
        forwardReserveBytes = ledger.forwardReserveBytes
    }

    static func derive(profile: QwenRegisteredDenseModelProfile, plan: QwenLayerStagePlan,
        requirement: QwenDenseStorageRequirement, source: QwenDenseSourceReadPlan,
        admission: QwenDenseShortReferenceAdmission, ledger: QwenDenseShortRequestLedger,
        allocationBounds: [Int]
    ) throws -> Self {
        let rebuilt = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: .fullReference)
        guard requirement.role == .fullReference, requirement.fingerprint == rebuilt.fingerprint,
              requirement.selectedInertBytes == 0, requirement.selectedActiveBytes == profile.sourceTensorBytes,
              source.registeredProfileFingerprint == profile.fingerprint,
              source.registeredRequirementFingerprint == requirement.fingerprint,
              source.tensors.map(\.canonical) == profile.canonicalTensors,
              source.sourceBytes == profile.sourceTensorBytes,
              source.largestSourceBytes == profile.largestSourceTensorBytes,
              admission.metadata.specification.model == profile.model,
              admission.metadata.configuration == profile.configuration,
              admission.metadata.manifest == profile.manifest,
              admission.metadata.plan.fingerprint == plan.fingerprint,
              plan.stages[0].sourceRange.upperBound == profile.geometry.layers / 2,
              ledger.scope == .fullReference, ledger.model == profile.model,
              ledger.modelProfileFingerprint == profile.fingerprint, ledger.planFingerprint == plan.fingerprint,
              ledger.recordedRequestFingerprint == admission.request.fingerprint,
              ledger.promptCount == 3, ledger.chunkSize == 2, ledger.outputCount == 2,
              ledger.teacherCount == 1, ledger.maximumTokens == 5,
              ledger.committedFrontiers == [2, 3, 4], ledger.forwardReserveBytes > 0 else {
            throw ProbeError("Short full-reference budget differs in source, role, Plan or recorded request")
        }
        guard source.tensors.count == allocationBounds.count,
              zip(source.tensors, allocationBounds).allSatisfy({ $0.1 >= $0.0.canonical.byteCount }),
              source.tensors.allSatisfy({ ["uint32", "bfloat16"].contains($0.loadedDType) }) else {
            throw ProbeError("Short full-reference allocator bounds or loaded types differ")
        }
        let rounded = try QwenLongPrefillCheckedBytes.sum(allocationBounds)
        return .init(profile: profile, requirement: requirement, source: source, admission: admission,
            ledger: ledger, allocationBounds: allocationBounds, rounded: rounded)
    }

    func remainingAllocationBytes(after ordinal: Int) throws -> Int {
        guard (0...tensors.count).contains(ordinal) else {
            throw ProbeError("Short full-reference load progress is outside its source inventory")
        }
        return try QwenLongPrefillCheckedBytes.sum(Array(allocationBounds.dropFirst(ordinal)))
    }

    func requireEntry(name: String, shape: [Int], sourceDType: String, byteCount: Int, ordinal: Int) throws {
        guard tensors.indices.contains(ordinal) else { throw ProbeError("Short full-reference reads were consumed") }
        let expected = tensors[ordinal]
        guard name == expected.name, shape == expected.shape,
              sourceDType == expected.sourceDType, byteCount == expected.byteCount else {
            throw ProbeError("Short full-reference attempted a different or unordered tensor")
        }
    }
}
