import Foundation

/// Exact CPU request/metadata identity for the new full-reference loading scope.
/// This does not authorize payload reads, model arithmetic or allocation.
struct QwenDenseShortReferenceAdmission {
    let metadata: QwenDenseConstructorAdmission
    let request: QwenLayerStageRecordedRequest
    let promptData: Data, teacherData: Data
    let promptSHA256: String, teacherSHA256: String, fingerprint: String
    let maximumTokens = 5
    let scope = "registered_dense_short_reference_3_2_2_v1"
    let resourceAdmissionPerformed = false, forwardExecutionAuthorized = false

    private init(metadata: QwenDenseConstructorAdmission, request: QwenLayerStageRecordedRequest,
        prompt: Data, teacher: Data, promptSHA256: String, teacherSHA256: String
    ) {
        self.metadata = metadata; self.request = request
        promptData = prompt; teacherData = teacher
        self.promptSHA256 = promptSHA256; self.teacherSHA256 = teacherSHA256
        fingerprint = QwenDenseProfileIdentity.fingerprint([
            "registered-dense-short-reference-admission-v1", metadata.specification.model.rawValue,
            metadata.specification.configurationSHA256, metadata.specification.manifestSHA256,
            metadata.specification.artifactSHA256, metadata.plan.fingerprint,
            request.fingerprint, promptSHA256, teacherSHA256,
            "prompt=3|chunk=2|teacher=1|output=2|capacity=5",
        ])
    }

    static func admit(metadata: QwenDenseConstructorAdmission, requestID: UUID,
        promptData: Data, promptSHA256: String, teacherData: Data, teacherSHA256: String
    ) throws -> Self {
        guard (1...4096).contains(promptData.count), (1...4096).contains(teacherData.count),
              QwenDenseProfileIdentity.isSHA256(promptSHA256), QwenDenseProfileIdentity.isSHA256(teacherSHA256),
              QwenDenseProfileIdentity.sha256(promptData) == promptSHA256,
              QwenDenseProfileIdentity.sha256(teacherData) == teacherSHA256,
              metadata.plan.stages.count == 2,
              metadata.plan.stages[0].sourceRange == 0..<(metadata.specification.layers / 2),
              metadata.plan.stages[1].sourceRange == (metadata.specification.layers / 2)..<metadata.specification.layers else {
            throw ProbeError("Short reference requires exact bounded raw inputs and the default registered Plan")
        }
        try validateWorkerJSON(promptData); try validateWorkerJSON(teacherData)
        let prompt = try JSONDecoder().decode([Int].self, from: promptData)
        let teacher = try JSONDecoder().decode([Int].self, from: teacherData)
        guard prompt.count == 3, teacher.count == 1,
              let root = try JSONSerialization.jsonObject(with: metadata.configuration) as? [String: Any] else {
            throw ProbeError("Short reference requires three prompt IDs and one teacher ID")
        }
        let text = root["text_config"] as? [String: Any] ?? root
        let vocabulary = try QwenStageMetadata.integer(text, "vocab_size", limit: 262144)
        let context = try QwenStageMetadata.integer(text, "max_position_embeddings", limit: 1048576)
        guard context >= 5 else { throw ProbeError("Short reference requires capacity for five tokens") }
        let request = try QwenLayerStageRecordedRequest(request: .init(requestID: requestID,
            promptCount: 3, chunkSize: 2, outputCount: 2), vocabularySize: vocabulary, prompt: prompt, teacher: teacher)
        guard request.steps.count == 3, request.steps.map(\.committedTokens) == [2, 3, 4],
              request.steps.map({ $0.frame.phase }) == [.prefill, .prefill, .decode],
              request.steps.map({ $0.frame.tokenCount }) == [2, 1, 1],
              request.steps.map({ $0.frame.finalPromptChunk }) == [false, true, false] else {
            throw ProbeError("Short reference recorded schedule differs from its closed geometry")
        }
        return .init(metadata: metadata, request: request, prompt: promptData, teacher: teacherData,
            promptSHA256: promptSHA256, teacherSHA256: teacherSHA256)
    }
}
