import Foundation

/// All amounts and the policy hash are independently supplied by the caller.
/// Syntactic validation establishes no provenance, OS observation, measured
/// reserve, allocation availability or device eligibility. This is not a permit.
struct QwenDenseResourcePlanningInput: Encodable {
    let policySHA256: String
    let requirementFingerprint: String
    let nativeWorkspaceReserveBytes: Int
    let allocatorAndFrameworkReserveBytes: Int
    let cpuMetadataAndEvidenceReserveBytes: Int
    let operatingSystemReserveBytes: Int
    let totalProcessPlanningCeilingBytes: Int
    let provenanceVerified = false, observedCurrentResources = false

    init(policySHA256: String, requirementFingerprint: String,
         nativeWorkspaceReserveBytes: Int, allocatorAndFrameworkReserveBytes: Int,
         cpuMetadataAndEvidenceReserveBytes: Int, operatingSystemReserveBytes: Int,
         totalProcessPlanningCeilingBytes: Int) throws {
        guard QwenDenseProfileIdentity.isSHA256(policySHA256), QwenDenseProfileIdentity.isSHA256(requirementFingerprint),
              [nativeWorkspaceReserveBytes, allocatorAndFrameworkReserveBytes, cpuMetadataAndEvidenceReserveBytes,
               operatingSystemReserveBytes, totalProcessPlanningCeilingBytes].allSatisfy({ $0 > 0 }) else {
            throw QwenDenseProfileError("Planning requires explicit positive reserves, ceiling and independently supplied policy identity")
        }
        self.policySHA256 = policySHA256; self.requirementFingerprint = requirementFingerprint
        self.nativeWorkspaceReserveBytes = nativeWorkspaceReserveBytes
        self.allocatorAndFrameworkReserveBytes = allocatorAndFrameworkReserveBytes
        self.cpuMetadataAndEvidenceReserveBytes = cpuMetadataAndEvidenceReserveBytes
        self.operatingSystemReserveBytes = operatingSystemReserveBytes
        self.totalProcessPlanningCeilingBytes = totalProcessPlanningCeilingBytes
    }
}

struct QwenDenseResourcePlan: Encodable {
    let kind = "qwen_dense_resource_planning_result", schemaVersion = 1
    let requirementFingerprint: String, inputFingerprint: String
    let partialNamedBufferLedgerBytes: Int, explicitCallerReserveBytes: Int
    let totalPlannedBytes: Int, callerCeilingBytes: Int, unassignedPlanningHeadroomBytes: Int
    let fitsCallerPlanningCeiling: Bool
    let callerResourcePolicyProvenanceVerified = false, currentOSOrRuntimeAdmissionPerformed = false
    let fusionAllowanceIsPeakProof = false, workspaceReserveIsMeasuredByThisCode = false
    let wholeProcessMemorySafetyEstablished = false, runtimeExecutionAuthorized = false

    private init(requirement: QwenDenseStorageRequirement, input: QwenDenseResourcePlanningInput,
                 reserve: Int, total: Int) throws {
        self.requirementFingerprint = requirement.fingerprint
        self.inputFingerprint = try QwenDenseProfileIdentity.encodedFingerprint(input)
        self.partialNamedBufferLedgerBytes = requirement.partialNamedBufferLedgerBytes
        self.explicitCallerReserveBytes = reserve; self.totalPlannedBytes = total
        self.callerCeilingBytes = input.totalProcessPlanningCeilingBytes
        self.fitsCallerPlanningCeiling = total <= input.totalProcessPlanningCeilingBytes
        self.unassignedPlanningHeadroomBytes = max(0, input.totalProcessPlanningCeilingBytes - total)
    }

    static func calculate(requirement: QwenDenseStorageRequirement,
                          input: QwenDenseResourcePlanningInput) throws -> Self {
        guard input.requirementFingerprint == requirement.fingerprint else {
            throw QwenDenseProfileError("Caller resource planning input belongs to a different model, Plan or role")
        }
        let reserve = try QwenLongPrefillCheckedBytes.sum([input.nativeWorkspaceReserveBytes,
            input.allocatorAndFrameworkReserveBytes, input.cpuMetadataAndEvidenceReserveBytes, input.operatingSystemReserveBytes])
        let total = try QwenLongPrefillCheckedBytes.sum([requirement.partialNamedBufferLedgerBytes, reserve])
        return try Self(requirement: requirement, input: input, reserve: reserve, total: total)
    }
}
