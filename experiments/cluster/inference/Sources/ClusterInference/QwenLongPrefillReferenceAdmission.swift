import Foundation

/// Pure admission from retained bytes. The caller obtains `arithmetic` from the
/// actual process environment before MLX initialization; no global reread here.
/// This owns no file handle, model, native state or externally supplied reference.
struct QwenRegistered9BLongPrefillReferenceAdmission {
    let configuration: Data
    let plan: QwenLayerStagePlan
    let request: QwenLayerStageProfiledPrefillRecordedRequest
    let resource: QwenRegistered9BLongPrefillAdmission.Receipt
    let arithmetic: QwenLongPrefillArithmeticEnvironment.Receipt
    let arithmeticEnvironmentSHA256: String
    let promptFileSHA256: String
    let promptTokenIDsSHA256: String

    init(configuration: Data, expectedArtifactAggregateSHA256: String,
         promptData: Data, expectedPromptSHA256: String,
         request: QwenLayerStageProfiledPrefillRequestSpec,
         arithmetic: QwenLongPrefillArithmeticEnvironment.Receipt, stageCut: Int? = nil) throws {
        guard request.profile == .longPrefill8KV1,
              request.promptCount == 8192, request.chunkSize == 512,
              request.outputCount == 1, request.batchSize == 1,
              request.prefillFrameCount == 16, request.maximumTokens == 8193,
              !promptData.isEmpty, promptData.count <= 65_536,
              Self.isSHA256(expectedPromptSHA256), sha256(promptData) == expectedPromptSHA256 else {
            throw ProbeError("Registered long reference requires the explicit 8192/512/1 profile and independently pinned bounded prompt bytes")
        }
        // Require the precise receipt schema/constants. Its provenance remains
        // the caller's early admission, not a claim that a copied dictionary
        // could establish the state of already-initialized native libraries.
        let canonicalArithmetic = try QwenLongPrefillArithmeticEnvironment.admit(
            QwenLongPrefillArithmeticEnvironment.requiredValues)
        guard arithmetic == canonicalArithmetic else {
            throw ProbeError("Long reference arithmetic receipt differs from the admitted source contract")
        }
        let resource = try QwenRegistered9BLongPrefillAdmission.admit(
            configuration: configuration, expectedArtifactAggregateSHA256: expectedArtifactAggregateSHA256,
            promptCount: request.promptCount, chunkSize: request.chunkSize, outputCount: request.outputCount,
            batchSize: request.batchSize, teacherTokenCount: 0, nativeDType: "bfloat16",
            bf16ConversionEnabled: true)
        try validateWorkerJSON(promptData)
        let prompt = try JSONDecoder().decode([Int].self, from: promptData)
        let recorded = try QwenLayerStageProfiledPrefillRecordedRequest(request: request,
            vocabularySize: 248_320, prompt: prompt, teacher: [])
        let plan = try QwenLongPrefillStageCut.makePlan(configuration: configuration, stageCut: stageCut)
        guard plan.layers == 32, plan.interval == 4, recorded.steps.count == 16,
              recorded.steps.enumerated().allSatisfy({ index, step in
                  step.frame.sequence == index && step.frame.phase == .prefill
                      && step.frame.tokenOffset == index * 512 && step.frame.tokenCount == 512
                      && step.frame.finalPromptChunk == (index == 15)
                      && step.committedTokens == (index + 1) * 512
              }) else { throw ProbeError("Registered reference plan or exact sixteen-frame timeline differs") }
        self.configuration = configuration; self.plan = plan; self.request = recorded
        self.resource = resource; self.arithmetic = arithmetic
        self.arithmeticEnvironmentSHA256 = sha256(try canonicalJSONData(arithmetic))
        self.promptFileSHA256 = expectedPromptSHA256
        self.promptTokenIDsSHA256 = sha256(Data(prompt.map(String.init).joined(separator: ",").utf8))
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    }
}
