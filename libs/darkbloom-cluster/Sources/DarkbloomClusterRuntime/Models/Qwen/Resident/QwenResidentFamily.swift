import DarkbloomClusterProtocol
import Foundation
import MLXNN

// The registered Qwen models as one resident family: each requirement is the
// call the stage machinery already made, unchanged.

extension QwenResidentAdmission: LayerStageResidentAdmission {
    var arithmeticContract: String { arithmetic.contract }
    var runtimeModelID: String { specification.model.rawValue }
    var supportedGenerationModes: [ClusterGenerationMode] { definition.supportedGenerationModes }

    func loadResidentStage(check: () throws -> Void,
                           constructed: (Module) -> Void) throws -> any LayerStageResidentStage {
        try loadQwenResidentStage(self, check: check, constructed: constructed)
    }
}

extension QwenResidentLoadedStage: LayerStageResidentStage {
    func namedStateByteCeiling() throws -> Int {
        try QwenResidentResourceCeilings(model: profile.model).namedStateByteCeiling
    }

    func requestAllowance(plan: QwenLayerStagePlan, rank: Int, maximumTokens: Int, chunkSize: Int,
                          bound: (Int) throws -> Int) throws -> QwenResidentRequestAllowance {
        try QwenResidentRequestAllowance.derive(profile: profile, plan: plan, rank: rank,
            maximumTokens: maximumTokens, chunkSize: chunkSize, bound: bound)
    }

    func diagnosticResources(plan: QwenLayerStagePlan, request: QwenLayerStageGenerationRequest, rank: Int,
                             requestAllowance: QwenResidentRequestAllowance) throws -> QwenGenerationDiagnosticResources {
        try QwenGenerationDiagnosticResources(loaded: loaded, profile: profile, plan: plan, request: request,
            rank: rank, requestAllowance: requestAllowance)
    }

    var handoffGeometry: QwenLongPrefillBudgetGeometry? { profile.geometry }
}
