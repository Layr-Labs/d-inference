import Foundation

/// Software bounds supplied by a qualified model adapter, not a load/resource
/// permit. Source identity and resource admission are checked separately.
struct QwenLayerStageGenerationProfile: Equatable, Encodable {
    let identifier: String
    let vocabularySize: Int
    let hiddenSize: Int
    let activationDType: String
    let maximumPromptTokens: Int
    let maximumChunkTokens: Int
    let maximumOutputTokens: Int
    let maximumContextTokens: Int
    /// The dtype of the logits row the output rank selects from, when it is not
    /// the activation dtype. Nil for every model whose head returns its
    /// activation dtype, and then it is in neither the fingerprint nor the encoding.
    let logitsDType: String?
    let fingerprint: String

    /// The dtype of the row a token is selected from and a recording captures.
    var selectedRowDType: String { logitsDType ?? activationDType }

    init(identifier: String, vocabularySize: Int, hiddenSize: Int, activationDType: String,
         maximumPromptTokens: Int, maximumChunkTokens: Int, maximumOutputTokens: Int,
         maximumContextTokens: Int, logitsDType: String? = nil) throws {
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
        if let logitsDType {
            guard logitsDType != activationDType else {
                throw ProbeError("A logits dtype is named only when it differs from the activation dtype")
            }
            _ = try qwenStageWireElementBytes(logitsDType)
        }
        self.logitsDType = logitsDType
        self.identifier = identifier; self.vocabularySize = vocabularySize
        self.hiddenSize = hiddenSize; self.activationDType = activationDType
        self.maximumPromptTokens = maximumPromptTokens; self.maximumChunkTokens = maximumChunkTokens
        self.maximumOutputTokens = maximumOutputTokens; self.maximumContextTokens = maximumContextTokens
        var fields = [
            "qwen-stage-generation-profile-v1", identifier, String(vocabularySize), String(hiddenSize),
            activationDType, String(maximumPromptTokens), String(maximumChunkTokens),
            String(maximumOutputTokens), String(maximumContextTokens),
        ]
        if let logitsDType { fields.append("logits=" + logitsDType) }
        fingerprint = sha256(Data(fields.joined(separator: "|").utf8))
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
    private(set) var prefillFrameCount: Int
    let fingerprint: String
    /// Prompt tokens whose committed state both ranks restored from their own
    /// prefix caches before the first forward. Zero for a cold request.
    private(set) var reusedPrefixTokens = 0
    /// The prompt's last token runs in a frame of its own, so that the state
    /// after `promptCount - 1` tokens is an exact frame boundary both ranks
    /// can keep. Both ranks agree on this before the first forward.
    private(set) var splitsFinalPromptToken = false
    /// End offsets of the prefill frames, in order. Nil keeps the original
    /// fixed-chunk plan from offset zero.
    private var prefillFrameEnds: [Int]?
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

    /// The same request with an agreed prefix plan. Prefill frames start at
    /// `reusedPrefix` and end on the global chunk grid (multiples of the chunk
    /// size), so a suffix after a grid-aligned hit runs exactly the frames a
    /// cold request runs there; with `splitFinalToken` the last prompt token
    /// runs alone. The fingerprint is the request's own and does not change.
    func planned(reusedPrefix: Int, splitFinalToken: Bool) throws -> QwenLayerStageGenerationRequest {
        guard reusedPrefix >= 0, reusedPrefix < promptCount,
              !splitFinalToken || promptCount >= 2 || reusedPrefix == 0 else {
            throw ProbeError("A prefix plan must leave at least one prompt token to compute")
        }
        var copy = self
        copy.reusedPrefixTokens = reusedPrefix
        copy.splitsFinalPromptToken = splitFinalToken && promptCount >= 2
        copy.prefillFrameEnds = Self.frameEnds(promptCount: promptCount, chunkSize: chunkSize,
            start: reusedPrefix, splitFinalToken: copy.splitsFinalPromptToken)
        copy.prefillFrameCount = copy.prefillFrameEnds!.count
        return copy
    }

    /// Frame ends from `start`: the next multiples of the chunk size, then
    /// `promptCount - 1` when the last token is split off, then `promptCount`.
    static func frameEnds(promptCount: Int, chunkSize: Int, start: Int, splitFinalToken: Bool) -> [Int] {
        let last = splitFinalToken ? promptCount - 1 : promptCount
        var ends: [Int] = [], offset = start
        while offset < last {
            let next = min(last, (offset / chunkSize + 1) * chunkSize)
            ends.append(next); offset = next
        }
        if splitFinalToken { ends.append(promptCount) }
        return ends
    }

    /// Prompt frontiers at which a stage can keep its committed state: grid
    /// multiples of `stride` and the split frontier `promptCount - 1`, all
    /// after the reused prefix. Empty unless the last token is split off.
    func prefixCaptureFrontiers(stride: Int) -> Set<Int> {
        guard splitsFinalPromptToken, stride > 0, let ends = prefillFrameEnds else { return [] }
        return Set(ends.filter { $0 == promptCount - 1 || ($0 < promptCount - 1 && $0 % stride == 0) })
    }

    func frame(sequence: Int) throws -> QwenLayerStageFrame {
        guard (0..<forwardCount).contains(sequence) else { throw ProbeError("Generation frame exceeds request") }
        if sequence < prefillFrameCount, let ends = prefillFrameEnds {
            let offset = sequence == 0 ? reusedPrefixTokens : ends[sequence - 1]
            return .init(sequence: sequence, phase: .prefill, tokenOffset: offset,
                         tokenCount: ends[sequence] - offset, finalPromptChunk: ends[sequence] == promptCount)
        }
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
