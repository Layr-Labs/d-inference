import Foundation

/// Pure, explicitly selected registered-model reference admission. Model and
/// request ownership are established later by the existing resource owner.
struct QwenRegisteredGenerationReferenceSource {
    let configuration: Data
    let manifest: Data
    let definition: QwenResidentModelDefinition
    let resource: QwenDenseRegisteredResourceProfile
    let plan: QwenLayerStagePlan
    let request: QwenLayerStageGenerationRequest
    let arithmetic: QwenLongPrefillArithmeticEnvironment.Receipt
    let arithmeticEnvironmentSHA256: String
    let promptFileSHA256: String
    let promptTokenIDsSHA256: String

    var specification: QwenDenseRegisteredSpecification { definition.specification }

    static func profile(definition: QwenResidentModelDefinition) throws -> QwenLayerStageGenerationProfile {
        try .init(identifier: definition.profileID, vocabularySize: 248_320,
            hiddenSize: definition.specification.hidden, activationDType: "bfloat16",
            maximumPromptTokens: 8192, maximumChunkTokens: QwenDenseRegisteredResourceProfile.maximumChunkTokens,
            maximumOutputTokens: 128, maximumContextTokens: QwenDenseRegisteredResourceProfile.maximumContextTokens)
    }

    init(definition: QwenResidentModelDefinition, configuration: Data, manifest: Data,
         promptData: Data, expectedPromptSHA256: String, promptCount: Int,
         requestID: UUID, stageCut: Int, chunkSize: Int, outputCount: Int,
         stopTokenIDs: Set<Int>, arithmetic: QwenLongPrefillArithmeticEnvironment.Receipt) throws {
        let specification = definition.specification
        guard (1...1_048_576).contains(configuration.count),
              (1...4_194_304).contains(manifest.count), (1...65_536).contains(promptData.count),
              sha256(configuration) == specification.configurationSHA256,
              sha256(manifest) == specification.manifestSHA256,
              qwenStageWireIsSHA256(expectedPromptSHA256), sha256(promptData) == expectedPromptSHA256,
              definition.supportedCuts.contains(stageCut),
              arithmetic == (try QwenLongPrefillArithmeticEnvironment.admit(
                QwenLongPrefillArithmeticEnvironment.requiredValues)) else {
            throw ProbeError("Registered generation reference source, arithmetic or selected cut differs")
        }
        try validateWorkerJSON(promptData)
        let tokens = try JSONDecoder().decode([Int].self, from: promptData)
        guard tokens.count == promptCount else { throw ProbeError("Declared reference prompt count differs from pinned IDs") }
        let profile = try Self.profile(definition: definition)
        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: requestID,
            promptTokenIDs: tokens, chunkSize: chunkSize, outputCount: outputCount, stopTokenIDs: stopTokenIDs)
        let resource = try QwenDenseRegisteredResourceProfile(specification: specification)
        _ = try resource.namedStateBudget(maximumTokens: request.maximumTokens,
            chunkSize: min(request.chunkSize, request.promptCount))
        let plan = try QwenLayerStagePlan(configuration: configuration,
            ranges: [0..<stageCut, stageCut..<specification.layers], activeMTP: false)
        guard plan.layers == specification.layers, plan.interval == resource.geometry.fullAttentionInterval else {
            throw ProbeError("Registered generation reference Plan differs from model geometry")
        }
        self.configuration = configuration; self.manifest = manifest; self.definition = definition
        self.resource = resource; self.plan = plan; self.request = request; self.arithmetic = arithmetic
        arithmeticEnvironmentSHA256 = sha256(try canonicalJSONData(arithmetic))
        promptFileSHA256 = expectedPromptSHA256
        promptTokenIDsSHA256 = sha256(Data(tokens.map(String.init).joined(separator: ",").utf8))
    }
}
