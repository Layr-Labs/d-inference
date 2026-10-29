import Foundation

@main enum ReferenceCheck {
    static func main() throws {
        var accepted: [String] = [], rejected: [String] = []
        func yes(_ name: String, _ value: Bool) throws {
            guard value else { throw ProbeError("Reference fixture failed: " + name) }
            accepted.append(name)
        }
        func no(_ name: String, _ body: () throws -> Void) throws {
            do { try body() } catch { rejected.append(name); return }
            throw ProbeError("Reference fixture accepted: " + name)
        }
        let configuration = FileHandle.standardInput.readDataToEndOfFile()
        guard configuration.count == 3118,
              sha256(configuration) == QwenRegistered9BLongPrefillAdmission.expectedConfigurationSHA256 else {
            throw ProbeError("Reference fixture requires the retained registered9B raw config")
        }
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let prompt = (0..<8192).map { $0 % 1000 }
        let promptData = try JSONEncoder().encode(prompt)
        let arithmetic = try QwenLongPrefillArithmeticEnvironment.admit(QwenLongPrefillArithmeticEnvironment.requiredValues)
        let source = try QwenRegistered9BLongPrefillReferenceAdmission(configuration: configuration,
            expectedArtifactAggregateSHA256: QwenRegistered9BLongPrefillAdmission.expectedArtifactAggregateSHA256,
            promptData: promptData, expectedPromptSHA256: sha256(promptData),
            request: .init(profile: .longPrefill8KV1, requestID: id, batchSize: 1, promptCount: 8192,
                           chunkSize: 512, outputCount: 1), arithmetic: arithmetic, stageCut: 12)
        func profile(hidden: Int = 4096, vocabulary: Int = 248320,
                     dtype: String = "bfloat16") throws -> QwenLayerStageGenerationProfile {
            try .init(identifier: "fixture9b_generation", vocabularySize: vocabulary,
                hiddenSize: hidden, activationDType: dtype, maximumPromptTokens: 8192,
                maximumChunkTokens: 512, maximumOutputTokens: 256, maximumContextTokens: 8448)
        }
        func request(output: Int = 128, ids: [Int]? = nil, uuid: UUID? = nil,
                     chunk: Int = 512, p: QwenLayerStageGenerationProfile? = nil
        ) throws -> QwenLayerStageGenerationRequest {
            try .init(profile: p ?? profile(), requestID: uuid ?? id,
                promptTokenIDs: ids ?? prompt, chunkSize: chunk, outputCount: output, stopTokenIDs: [1001])
        }
        let full = try request()
        let admitted = try QwenGenerationReferenceAdmission(source: source, request: full)
        try yes("P+O capacity and exact final frontier", full.maximumTokens == 8320 && full.forwardCount == 143
            && full.finalCommittedTokens == 8319 && admitted.source.plan.stages[0].sourceRange == 0..<12)
        try yes("recomputed named terms replace old output-one terms",
            admitted.requirements.namedTensors.conservativeStateAndBoundaryBytes == 754_188_320
            && source.resource.budget.conservativeStateAndBoundaryBytes == 745_345_056
            && admitted.requirements.maximumTokens == 8320)
        try yes("bounded current plus preceding row capture terms",
            admitted.requirements.capturedRowsCPUBytes == 2_979_840
            && admitted.requirements.temporaryFloat32RowBytes == 993_280
            && !admitted.requirements.resourceAdmissionPerformed)
        let length = try QwenGenerationReferenceCompletion(request: full, reason: .length,
            selectedTokenIDs: Array(repeating: 999, count: 128), completedFrames: 143)
        try length.requireSession(promptCount: 8192, outputCount: 128,
            committedPromptTokens: 8192, decodeForwardCount: 127, committedTokens: 8319)
        try yes("length commits127 decode inputs, not selected128th", length.committedTokens == 8319)
        let eos = try QwenGenerationReferenceCompletion(request: full, reason: .eos,
            selectedTokenIDs: [1001], completedFrames: 16)
        try eos.requireSession(promptCount: 8192, outputCount: 128,
            committedPromptTokens: 8192, decodeForwardCount: 0, committedTokens: 8192)
        try yes("EOS first target clean frontier", eos.committedTokens == 8192)
        let lateEOS = try QwenGenerationReferenceCompletion(request: full, reason: .eos,
            selectedTokenIDs: Array(repeating: 999, count: 127) + [1001], completedFrames: 143)
        try yes("EOS precedes length at final target", lateEOS.reason == .eos && lateEOS.committedTokens == 8319)
        let one = try QwenGenerationReferenceAdmission(source: source, request: request(output: 1))
        try yes("O1 remains bounded with original named terms", one.requirements.namedTensors == source.resource.budget)
        try no("changed UUID") { _ = try QwenGenerationReferenceAdmission(source: source,
            request: request(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000124")!)) }
        try no("changed raw logical prompt") { var other = prompt; other[0] = 1000
            _ = try QwenGenerationReferenceAdmission(source: source, request: request(ids: other)) }
        try no("changed chunk") { _ = try QwenGenerationReferenceAdmission(source: source, request: request(chunk: 256)) }
        try no("changed hidden geometry") { _ = try QwenGenerationReferenceAdmission(source: source, request: request(p: profile(hidden: 2048))) }
        try no("changed vocabulary") { _ = try QwenGenerationReferenceAdmission(source: source, request: request(p: profile(vocabulary: 248321))) }
        try no("changed dtype") { _ = try QwenGenerationReferenceAdmission(source: source, request: request(p: profile(dtype: "float16"))) }
        try no("reference output cap") { _ = try QwenGenerationReferenceAdmission(source: source, request: request(output: 129)) }
        try no("named tensor ceiling") { _ = try QwenGenerationReferenceRequirements(request: full,
            geometry: source.resource.geometry, namedTensorByteCeiling: 754_188_319) }
        try no("no tokens") { _ = try QwenGenerationReferenceCompletion(request: full, reason: .eos, selectedTokenIDs: [], completedFrames: 16) }
        try no("oversized token history") { _ = try QwenGenerationReferenceCompletion(request: full, reason: .length,
            selectedTokenIDs: Array(repeating: 999, count: 129), completedFrames: 144) }
        try no("negative token") { _ = try QwenGenerationReferenceCompletion(request: full, reason: .eos, selectedTokenIDs: [-1], completedFrames: 16) }
        try no("token equals vocabulary") { _ = try QwenGenerationReferenceCompletion(request: full, reason: .eos, selectedTokenIDs: [248320], completedFrames: 16) }
        try no("continued after EOS") { _ = try QwenGenerationReferenceCompletion(request: full, reason: .eos, selectedTokenIDs: [1001, 1001], completedFrames: 17) }
        try no("early length") { _ = try QwenGenerationReferenceCompletion(request: full, reason: .length, selectedTokenIDs: [999], completedFrames: 16) }
        try no("unadmitted EOS") { _ = try QwenGenerationReferenceCompletion(request: full, reason: .eos, selectedTokenIDs: [999], completedFrames: 16) }
        try no("length masks EOS") { _ = try QwenGenerationReferenceCompletion(request: full, reason: .length,
            selectedTokenIDs: Array(repeating: 999, count: 127) + [1001], completedFrames: 143) }
        try no("client stop is not a greedy reference") { _ = try QwenGenerationReferenceCompletion(request: full, reason: .clientStop, selectedTokenIDs: [999], completedFrames: 16) }
        try no("uncommitted frame") { _ = try QwenGenerationReferenceCompletion(request: full, reason: .eos, selectedTokenIDs: [1001], completedFrames: 15) }
        try no("invented extra frame") { _ = try QwenGenerationReferenceCompletion(request: full, reason: .eos, selectedTokenIDs: [1001], completedFrames: 17) }
        try no("wrong session prompt") { try eos.requireSession(promptCount: 8191, outputCount: 128, committedPromptTokens: 8192, decodeForwardCount: 0, committedTokens: 8192) }
        try no("wrong session capacity") { try eos.requireSession(promptCount: 8192, outputCount: 1, committedPromptTokens: 8192, decodeForwardCount: 0, committedTokens: 8192) }
        try no("incomplete session prompt") { try eos.requireSession(promptCount: 8192, outputCount: 128, committedPromptTokens: 8191, decodeForwardCount: 0, committedTokens: 8192) }
        try no("invented session decode") { try eos.requireSession(promptCount: 8192, outputCount: 128, committedPromptTokens: 8192, decodeForwardCount: 1, committedTokens: 8192) }
        try no("consumed final selection") { try length.requireSession(promptCount: 8192, outputCount: 128, committedPromptTokens: 8192, decodeForwardCount: 127, committedTokens: 8320) }
        let result: [String: Any] = ["kind": "full_generation_reference_cpu_check", "accepted": accepted,
            "rejected": rejected, "acceptedCount": accepted.count, "rejectedCount": rejected.count,
            "modelForwardExecuted": false, "nativeSessionRetirementExecuted": false,
            "liveResourceAdmissionPerformed": false, "fixtureTokensAreInvented": true]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data([10]))
    }
}
