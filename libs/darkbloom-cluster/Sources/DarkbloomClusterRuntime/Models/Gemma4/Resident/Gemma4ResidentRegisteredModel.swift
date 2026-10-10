import Foundation

extension QwenResidentCapabilityMetadata.RegisteredModel {
    /// The closed resident scope of one registered Gemma artifact.
    init(_ specification: Gemma4RegisteredSpecification) {
        manifestSHA256 = specification.manifestSHA256
        requiredArithmeticEnvironment = Gemma4ArithmeticEnvironment.requiredValues
        runtimeModelID = specification.model.rawValue
        profileID = Gemma4ResidentAdapterDefinition.profileID(specification.model)
        layerCount = Gemma4StageGeometry.layerCount
        supportedCuts = Gemma4ResidentAdapterDefinition.supportedCuts
        supportedPrefillSchedules = Gemma4ResidentAdapterDefinition.supportedPrefillSchedules
        supportedGenerationModes = Gemma4ResidentAdapterDefinition.supportedGenerationModes
    }
}
