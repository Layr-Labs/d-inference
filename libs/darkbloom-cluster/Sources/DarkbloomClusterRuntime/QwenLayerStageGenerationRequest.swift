import Foundation

/// Software bounds supplied by a qualified model adapter, not a load/resource
/// permit. Legacy and long-prefill profiles retain their separate admissions.
struct QwenLayerStageGenerationProfile: Equatable, Encodable {
    let identifier: String
    let vocabularySize: Int
    let hiddenSize: Int
    let activationDType: String
    let maximumPromptTokens: Int
    let maximumChunkTokens: Int
    let maximumOutputTokens: Int
    let maximumContextTokens: Int
    let fingerprint: String

    init(identifier: String, vocabularySize: Int, hiddenSize: Int, activationDType: String,
         maximumPromptTokens: Int, maximumChunkTokens: Int, maximumOutputTokens: Int,
         maximumContextTokens: Int) throws {
        guard !identifier.isEmpty, identifier.utf8.count <= 128,
              identifier.utf8.allSatisfy({ (33...126).contains($0) }),
              (1...262_144).contains(vocabularySize), (1...8192).contains(hiddenSize),
              (1...32_768).contains(maximumPromptTokens),
              (1...maximumPromptTokens).contains(maximumChunkTokens),
              (1...4096).contains(maximumOutputTokens),
              (maximumPromptTokens...32_768).contains(maximumContextTokens) else {
            throw ProbeError("Generation profile exceeds native software bounds")
        }
        _ = try qwenStageWireElementBytes(activationDType)
        self.identifier = identifier; self.vocabularySize = vocabularySize
        self.hiddenSize = hiddenSize; self.activationDType = activationDType
        self.maximumPromptTokens = maximumPromptTokens; self.maximumChunkTokens = maximumChunkTokens
        self.maximumOutputTokens = maximumOutputTokens; self.maximumContextTokens = maximumContextTokens
        fingerprint = sha256(Data([
            "qwen-stage-generation-profile-v1", identifier, String(vocabularySize), String(hiddenSize),
            activationDType, String(maximumPromptTokens), String(maximumChunkTokens),
            String(maximumOutputTokens), String(maximumContextTokens),
        ].joined(separator: "|").utf8))
    }
}

struct QwenLayerStageGenerationRequest: Equatable {
    let profile: QwenLayerStageGenerationProfile
    let requestID: UUID
    let promptTokenIDs: [Int]
    let stopTokenIDs: Set<Int>
    let chunkSize: Int
    let outputCount: Int
    let maximumTokens: Int
    let prefillFrameCount: Int
    let fingerprint: String
    var promptCount: Int { promptTokenIDs.count }
    var forwardCount: Int { prefillFrameCount + outputCount - 1 }
    var finalCommittedTokens: Int { promptCount + outputCount - 1 }

    init(profile: QwenLayerStageGenerationProfile, requestID: UUID, promptTokenIDs: [Int],
         chunkSize: Int, outputCount: Int, stopTokenIDs: Set<Int>) throws {
        guard (1...profile.maximumPromptTokens).contains(promptTokenIDs.count),
              (1...profile.maximumChunkTokens).contains(chunkSize),
              (1...profile.maximumOutputTokens).contains(outputCount),
              promptTokenIDs.count <= profile.maximumContextTokens - outputCount,
              promptTokenIDs.allSatisfy({ (0..<profile.vocabularySize).contains($0) }),
              stopTokenIDs.count <= 256,
              stopTokenIDs.allSatisfy({ (0..<profile.vocabularySize).contains($0) }) else {
            throw ProbeError("Generation request exceeds its adapter profile or token bounds")
        }
        self.profile = profile; self.requestID = requestID; self.promptTokenIDs = promptTokenIDs
        self.stopTokenIDs = stopTokenIDs; self.chunkSize = chunkSize; self.outputCount = outputCount
        maximumTokens = promptTokenIDs.count + outputCount
        prefillFrameCount = (promptTokenIDs.count - 1) / chunkSize + 1
        fingerprint = sha256(Data([
            "qwen-stage-generation-request-v1", profile.fingerprint, requestID.uuidString.lowercased(),
            "prompt=" + qwenGenerationTokenHash(promptTokenIDs), "chunk=\(chunkSize)", "output=\(outputCount)",
            "stop=" + stopTokenIDs.sorted().map(String.init).joined(separator: ","),
        ].joined(separator: "\n").utf8))
    }

    func frame(sequence: Int) throws -> QwenLayerStageFrame {
        guard (0..<forwardCount).contains(sequence) else { throw ProbeError("Generation frame exceeds request") }
        if sequence < prefillFrameCount {
            let offset = sequence * chunkSize
            let count = min(chunkSize, promptCount - offset)
            return .init(sequence: sequence, phase: .prefill, tokenOffset: offset,
                         tokenCount: count, finalPromptChunk: offset + count == promptCount)
        }
        return .init(sequence: sequence, phase: .decode,
                     tokenOffset: promptCount + sequence - prefillFrameCount, tokenCount: 1, finalPromptChunk: false)
    }
}

func qwenGenerationTokenHash(_ tokens: [Int]) -> String {
    // The existing native Boundary.tokenHash convention, without importing MLX.
    sha256(Data(tokens.map(String.init).joined(separator: ",").utf8))
}
