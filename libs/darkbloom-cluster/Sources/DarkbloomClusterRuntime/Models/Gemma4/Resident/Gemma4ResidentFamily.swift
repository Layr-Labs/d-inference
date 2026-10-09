import DarkbloomClusterProtocol
import Foundation
import MLXNN

// The registered Gemma 4 26B artifacts as one resident family.

extension Gemma4ResidentAdmission: LayerStageResidentAdmission {
    var arithmeticContract: String { arithmetic.contract }
    var runtimeModelID: String { specification.model.rawValue }
    var supportedGenerationModes: [ClusterGenerationMode] { Gemma4ResidentAdapterDefinition.supportedGenerationModes }

    /// Rank, local path and local uptime are intentionally absent. The explicit
    /// allocator and prefill policies must agree before either stage is loaded.
    func loadAgreementFingerprint() throws -> String {
        let identity = configuration.identity
        return sha256(try canonicalJSONData([
            "gemma4-resident-load-v1", identity.membershipEpoch.uuidString.lowercased(), identity.modelID,
            identity.configurationSHA256, identity.artifactSHA256, specification.manifestSHA256,
            plan.fingerprint, profile.fingerprint, arithmeticSHA256, jaccl.fingerprint,
            configuration.allocatorPolicy.rawValue,
        ] + identity.peers.flatMap { [$0.id, $0.buildSHA256] }
            + QwenResidentPrefillSelection.loadAgreementFields(configuration.prefillSchedule)))
    }

    func request(_ value: ClusterWorkerReservation, id: UUID, now: UInt64) throws -> QwenLayerStageGenerationRequest {
        guard value.profileID == profile.identifier, value.capacityLimitBytes > 0,
              value.stopTokenIDs == Array(Set(value.stopTokenIDs)).sorted(),
              value.deadlineUptimeNanoseconds > now,
              value.deadlineUptimeNanoseconds <= configuration.deadlineUptimeNanoseconds else {
            throw ProbeError("Resident reservation has wrong profile, stop IDs, capacity or local deadline")
        }
        return try .init(profile: profile, requestID: id, promptTokenIDs: value.promptTokenIDs,
            chunkSize: value.chunkSize, outputCount: value.outputCount, stopTokenIDs: Set(value.stopTokenIDs))
    }

    func loadResidentStage(check: () throws -> Void,
                           constructed: (Module) -> Void) throws -> any LayerStageResidentStage {
        try loadGemma4ResidentStage(self, check: check, constructed: constructed)
    }
}

extension Gemma4ResidentLoadedStage: LayerStageResidentStage {
    func namedStateByteCeiling() throws -> Int {
        try Gemma4ResidentResourceCeilings(specification: specification).namedStateByteCeiling
    }

    func requestAllowance(plan: QwenLayerStagePlan, rank: Int, maximumTokens: Int, chunkSize: Int,
                          bound: (Int) throws -> Int) throws -> QwenResidentRequestAllowance {
        guard plan.stages.count == 2, (0...1).contains(rank), loaded.plan.fingerprint == plan.fingerprint else {
            throw ProbeError("Resident request allowance requires this stage's admitted two-stage Plan")
        }
        let budget = try Gemma4StateBudget.estimate(maximumTokens: maximumTokens, chunkSize: chunkSize)
        guard budget.stateAndBoundaryBytes
                <= (try Gemma4ResidentResourceCeilings(specification: specification).namedStateByteCeiling) else {
            throw ProbeError("Resident request exceeds the model's named-state byte ceiling")
        }
        return try budget.allowance(bound: bound)
    }

    func diagnosticResources(plan: QwenLayerStagePlan, request: QwenLayerStageGenerationRequest, rank: Int,
                             requestAllowance: QwenResidentRequestAllowance) throws -> QwenGenerationDiagnosticResources {
        let receipt = loaded.receipt
        guard (0...1).contains(rank), loaded.stageIndex == rank, plan.stages.count == 2,
              sha256(plan.originalConfiguration) == specification.configurationSHA256,
              receipt.sourceConfigurationSHA256 == specification.configurationSHA256,
              receipt.verifiedAggregateSHA256 == specification.artifactSHA256,
              loaded.plan.fingerprint == plan.fingerprint, receipt.planSHA256 == plan.fingerprint,
              receipt.stagePlanSHA256 == plan.stages[rank].fingerprint,
              request.profile.vocabularySize == loaded.vocabularySize,
              request.profile.hiddenSize == Gemma4StageGeometry.hiddenSize,
              request.profile.activationDType == String(describing: loaded.activationDType) else {
            throw ProbeError("Diagnostic registered profile differs from the loaded generation source")
        }
        // A byte-only allowance is not a permit: rederive the exact request with
        // the actual allocator, then require the owner's reservation to match.
        let actual = try self.requestAllowance(plan: plan, rank: rank, maximumTokens: request.maximumTokens,
            chunkSize: min(request.chunkSize, request.promptCount),
            bound: QwenResidentResourceEnvironment.allocationBound)
        guard actual.stateBytes == requestAllowance.stateBytes, actual.fusionBytes == requestAllowance.fusionBytes,
              actual.reservedBytes == requestAllowance.reservedBytes else {
            throw ProbeError("Diagnostic allowance differs from the actual reserved generation geometry")
        }
        return try .init(rederivedAllowance: actual, request: request, rank: rank)
    }

    /// A sliding layer's ring has no hand-off yet, so this family does not hand over.
    var handoffGeometry: QwenLongPrefillBudgetGeometry? { nil }
}
