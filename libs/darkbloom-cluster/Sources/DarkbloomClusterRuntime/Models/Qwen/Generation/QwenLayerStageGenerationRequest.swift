import DarkbloomClusterProtocol
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
    /// Nil retains the existing [B,T,H] wire encoding and fingerprint. GLM's
    /// four residual streams cross intact as [B,T,4,H], before any final norm.
    let residualStreams: Int?
    let fingerprint: String

    /// The dtype of the row a token is selected from and a recording captures.
    var selectedRowDType: String { logitsDType ?? activationDType }
    var boundaryElementsPerToken: Int { hiddenSize * (residualStreams ?? 1) }

    func boundaryShape(tokenCount: Int) -> [Int] {
        if let residualStreams { return [1, tokenCount, residualStreams, hiddenSize] }
        return [1, tokenCount, hiddenSize]
    }

    init(identifier: String, vocabularySize: Int, hiddenSize: Int, activationDType: String,
         maximumPromptTokens: Int, maximumChunkTokens: Int, maximumOutputTokens: Int,
         maximumContextTokens: Int, logitsDType: String? = nil, residualStreams: Int? = nil) throws {
        guard !identifier.isEmpty, identifier.utf8.count <= 128,
              identifier.utf8.allSatisfy({ (33...126).contains($0) }),
              (1...262_144).contains(vocabularySize), (1...8192).contains(hiddenSize),
              (1...ClusterWorkerLimits.wirePromptTokens).contains(maximumPromptTokens),
              (1...maximumPromptTokens).contains(maximumChunkTokens),
              (1...ClusterWorkerLimits.wireOutputTokens).contains(maximumOutputTokens),
              (maximumPromptTokens...ClusterWorkerLimits.wireContextTokens).contains(maximumContextTokens),
              residualStreams == nil || residualStreams == 4 else {
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
        self.residualStreams = residualStreams
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
        if let residualStreams { fields.append("streams=\(residualStreams)") }
        fingerprint = sha256(Data(fields.joined(separator: "|").utf8))
    }
}

struct QwenLayerStageGenerationRequest: Equatable {
    let profile: QwenLayerStageGenerationProfile
    let requestID: UUID
    let promptTokenIDs: [Int]
    let mimoImages: ClusterMiMoImages?
    let stillImages: ClusterStillImages?
    let stopTokenIDs: Set<Int>
    let chunkSize: Int
    let outputCount: Int
    let maximumTokens: Int
    private(set) var prefillFrameCount: Int
    let fingerprint: String
    /// How the selecting rank draws each token; nil is greedy argmax, and then
    /// the fingerprint is exactly a greedy request's. Copies of the request
    /// (a planned prefix, a stage session's) share the one state, so the
    /// selecting rank's sampler (`sampler`, created on first use) and its
    /// history follow the request.
    let sampling: QwenStageSamplingState?
    /// Prompt tokens whose committed state both ranks restored from their own
    /// prefix caches before the first forward. Zero for a cold request.
    private(set) var reusedPrefixTokens = 0
    /// The prompt's last token runs in a frame of its own, so that the state
    /// after `promptCount - 1` tokens is an exact frame boundary both ranks
    /// can keep. Both ranks agree on this before the first forward.
    private(set) var splitsFinalPromptToken = false
    /// The decoding rank serves this request alone (`ClusterWorkerRoute`):
    /// bound into the fingerprint, so both ranks agree before the first forward.
    let decodingRankAlone: Bool
    /// End offsets of the prefill frames, in order. Nil keeps the original
    /// fixed-chunk plan from offset zero.
    private var prefillFrameEnds: [Int]?
    var promptCount: Int { promptTokenIDs.count }
    var forwardCount: Int { prefillFrameCount + outputCount - 1 }
    var finalCommittedTokens: Int { promptCount + outputCount - 1 }

    init(profile: QwenLayerStageGenerationProfile, requestID: UUID, promptTokenIDs: [Int],
         chunkSize: Int, outputCount: Int, stopTokenIDs: Set<Int>,
         sampling: ClusterWorkerSampling? = nil, route: ClusterWorkerRoute? = nil, mimoImages: ClusterMiMoImages? = nil, stillImages: ClusterStillImages? = nil) throws {
        try mimoImages?.validate(prompt:promptTokenIDs)
        try stillImages?.validateStructure(promptCount: promptTokenIDs.count)
        guard stillImages == nil || (mimoImages == nil && route == nil
            && profile.identifier == ClusterStillImages.glmProfileID) else { throw ProbeError("Foreign still-image request") }
        self.stillImages = stillImages
        self.mimoImages = mimoImages
        guard (1...profile.maximumPromptTokens).contains(promptTokenIDs.count),
              (1...profile.maximumChunkTokens).contains(chunkSize),
              (1...profile.maximumOutputTokens).contains(outputCount),
              promptTokenIDs.count <= profile.maximumContextTokens - outputCount,
              promptTokenIDs.allSatisfy({ (0..<profile.vocabularySize).contains($0) }),
              stopTokenIDs.count <= 256,
              stopTokenIDs.allSatisfy({ (0..<profile.vocabularySize).contains($0) }) else {
            throw ProbeError("Generation request exceeds its adapter profile or token bounds")
        }
        if let sampling {
            guard sampling.topK <= profile.vocabularySize,
                  sampling.logitBias.allSatisfy({ (0..<profile.vocabularySize).contains($0.tokenID) }) else {
                throw ProbeError("Generation sampling exceeds its adapter vocabulary")
            }
        }
        self.profile = profile; self.requestID = requestID; self.promptTokenIDs = promptTokenIDs
        self.stopTokenIDs = stopTokenIDs; self.chunkSize = chunkSize; self.outputCount = outputCount
        maximumTokens = promptTokenIDs.count + outputCount
        prefillFrameCount = (promptTokenIDs.count - 1) / chunkSize + 1
        self.sampling = try sampling.map { try QwenStageSamplingState($0, promptTokens: promptTokenIDs) }
        var fields = [
            "qwen-stage-generation-request-v1", profile.fingerprint, requestID.uuidString.lowercased(),
            "prompt=" + qwenGenerationTokenHash(promptTokenIDs), "chunk=\(chunkSize)", "output=\(outputCount)",
            "stop=" + stopTokenIDs.sorted().map(String.init).joined(separator: ","),
        ]
        // Both ranks agree on the sampling values; greedy requests keep their fingerprint.
        if let state = self.sampling { fields.append("sampling=" + state.fingerprint) }
        // A request the pair serves as placed keeps its fingerprint.
        decodingRankAlone = route == .decodingRankAlone
        if let route { fields.append("route=" + route.rawValue) }
        // Bind actual request pixels and owned positions before the bilateral
        // request agreement. Absent media preserves every legacy hash byte.
        if let mimoImages { fields.append("mimo-images=" + mimoImages.fingerprint) }
        if let stillImages { fields.append("still-images=" + stillImages.fingerprint) }
        fingerprint = sha256(Data(fields.joined(separator: "\n").utf8))
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

/// A sampled request's agreed values (MLX-free): the wire sampling, the prompt
/// the penalties see, and the fingerprint both ranks bind into the request.
/// The rank that selects tokens keeps the product's sampler here
/// (`QwenStageTokenSampler`, created on first use), so every copy of the
/// request draws from one history.
final class QwenStageSamplingState: Equatable {
    let wire: ClusterWorkerSampling
    let promptTokens: [Int]
    /// Every value of `wire`.
    let fingerprint: String
    /// The selecting rank's `QwenStageTokenSampler`; nil until first used.
    var tokenSampler: AnyObject?

    init(_ wire: ClusterWorkerSampling, promptTokens: [Int]) throws {
        guard !wire.isGreedyNoOp else { throw ProbeError("Greedy text needs no sampler") }
        self.wire = wire; self.promptTokens = promptTokens
        func bits(_ value: Float) -> String { String(value.bitPattern) }
        fingerprint = sha256(Data(([
            "qwen-stage-sampling-v1", bits(wire.temperature), bits(wire.topP), String(wire.topK), bits(wire.minP),
            bits(wire.repetitionPenalty), String(wire.repetitionContextSize), bits(wire.frequencyPenalty),
            bits(wire.presencePenalty), String(wire.seed), String(wire.stream),
        ] + wire.logitBias.map { "\($0.tokenID):\(bits($0.bias))" }).joined(separator: "|").utf8))
    }

    static func == (lhs: QwenStageSamplingState, rhs: QwenStageSamplingState) -> Bool {
        lhs.fingerprint == rhs.fingerprint
    }
}
