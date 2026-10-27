import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLMCommon
import MLXVLM

/// Metadata copied from the verified tower inventory before request admission.
/// It contains no weights, encoded payloads or mutable model-global state.
struct QwenMediaModelIdentity {
    let artifactSHA256, configurationSHA256, processorSHA256: String
    let configuration: Qwen35Configuration
    let featureDType: DType
}

/// Immutable prompt positions and executor-owned feature roots for one request.
/// The source identity and every three-axis value are reproduced on both ranks,
/// even though only rank zero receives encoded bytes or owns a vision tower.
final class QwenMediaRequestState {
    let media: ClusterQwenMedia
    let promptPositions: [Int32]
    let hiddenSize: Int
    let featureDType: DType
    let maximumContext: Int
    private(set) var features: [MLXArray] = []

    init(media: ClusterQwenMedia, prompt: [Int], identity: QwenMediaModelIdentity,
         maximumPrompt: Int, maximumContext: Int) throws {
        guard media.artifactSHA256 == identity.artifactSHA256,
            media.configurationSHA256 == identity.configurationSHA256,
            media.processorSHA256 == identity.processorSHA256,
            media.processorPolicy.rawValue == Qwen3VLMediaProcessor.policyID,
            maximumContext >= prompt.count, maximumContext <= Int(Int32.max) else {
            throw ProbeError("Qwen media request differs from the loaded tower or context")
        }
        let seam = identity.configuration.visionSeamConfiguration
        guard seam.imagePlaceholderTokenId == seam.imagePositionTokenId,
            seam.videoPlaceholderTokenId == seam.videoPositionTokenId else {
            throw ProbeError("Registered Qwen media marker roles differ")
        }
        try media.validate(prompt: prompt, imageToken: seam.imagePlaceholderTokenId,
            videoToken: seam.videoPlaceholderTokenId, startToken: seam.visionStartTokenId,
            endToken: seam.visionEndTokenId, maximumPromptTokens: maximumPrompt)
        self.media = media
        hiddenSize = identity.configuration.textConfiguration.hiddenSize
        featureDType = identity.featureDType
        self.maximumContext = maximumContext
        promptPositions = try Device.withDefaultDevice(.cpu) {
            try MLX.withError { errors in
                let result = try QwenVisionSeamSupport.positionResult(tokens: MLXArray(prompt.map(Int32.init)),
                    imageGrids: media.items.filter { $0.kind == .image }.map { THW($0.temporal, $0.height, $0.width) },
                    videoGrids: media.items.filter { $0.kind == .video }.map { THW($0.temporal, $0.height, $0.width) },
                    attentionMask: nil, seam: seam)
                eval(result.promptPositionIds); Stream.cpu.synchronize(); try errors.check()
                let values = result.promptPositionIds.asArray(Int32.self)
                try errors.check()
                guard result.decodeState.deltas == media.decodeDeltas,
                    ClusterQwenMedia.int32SHA256(values) == media.positionIDsSHA256,
                    values.count == prompt.count * 3, values.allSatisfy({ $0 >= 0 }) else {
                    throw ProbeError("Qwen three-axis positions differ from the authenticated receipt")
                }
                return values
            }
        }
    }

    /// A different image or video with identical placeholder IDs cannot reuse
    /// this request's recurrent/KV prefix. Nil media retains the old key path.
    var prefixIdentity: String { media.fingerprint }

    func positions(in range: Range<Int>) throws -> MLXArray {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= maximumContext else {
            throw ProbeError("Qwen media position range exceeds its admitted request")
        }
        var values = [Int32](); values.reserveCapacity(3 * range.count)
        for axis in 0..<3 {
            for offset in range {
                if offset < media.promptLength {
                    values.append(promptPositions[axis * media.promptLength + offset])
                } else {
                    let position = offset + Int(media.decodeDeltas[0])
                    guard position >= 0, position <= Int(Int32.max) else {
                        throw ProbeError("Qwen media decode position exceeds Int32")
                    }
                    values.append(Int32(position))
                }
            }
        }
        return MLXArray(values, [3, 1, range.count])
    }

    /// Only already evaluated, authenticated native features enter this owner.
    /// Evaluation, collective agreement and allocation custody are caller-owned.
    func installFeatures(_ values: [MLXArray]) throws {
        guard features.isEmpty, values.count == media.items.count else {
            throw ProbeError("Qwen media features were installed twice or incompletely")
        }
        for (item, value) in zip(media.items, values) {
            guard value.shape == [item.tokenCount, hiddenSize], value.dtype == featureDType else {
                throw ProbeError("Qwen media feature shape or dtype differs from the tower")
            }
        }
        features = values
    }

    /// Replace only the overlapping authenticated spans. This preserves the
    /// ordinary embedding dtype/promotion and the chunk's exact text positions.
    func merging(_ text: MLXArray, range: Range<Int>) throws -> MLXArray {
        guard text.shape == [1, range.count, hiddenSize], !range.isEmpty,
            range.lowerBound >= 0, range.upperBound <= maximumContext,
            [.float16, .bfloat16, .float32].contains(text.dtype) else {
            throw ProbeError("Qwen media embedding chunk differs from its request")
        }
        let indices = media.items.indices.filter {
            media.items[$0].tokenOffset < range.upperBound
                && media.items[$0].tokenOffset + media.items[$0].tokenCount > range.lowerBound
        }.sorted { media.items[$0].tokenOffset < media.items[$1].tokenOffset }
        guard !indices.isEmpty else { return text }
        guard features.count == media.items.count else { throw ProbeError("Qwen media features are not ready") }
        var pieces: [MLXArray] = [], cursor = range.lowerBound
        for index in indices {
            let item = media.items[index]
            let lower = max(range.lowerBound, item.tokenOffset)
            let upper = min(range.upperBound, item.tokenOffset + item.tokenCount)
            if cursor < lower { pieces.append(text[0..., (cursor - range.lowerBound)..<(lower - range.lowerBound), 0...]) }
            pieces.append(features[index][(lower - item.tokenOffset)..<(upper - item.tokenOffset), 0...]
                .expandedDimensions(axis: 0).asType(text.dtype))
            cursor = upper
        }
        if cursor < range.upperBound { pieces.append(text[0..., (cursor - range.lowerBound)..., 0...]) }
        return pieces.count == 1 ? pieces[0] : concatenated(pieces, axis: 1)
    }

    /// Called only after the executor's checked native drain; the reservation
    /// keeps this state and its charge if that drain fails.
    func releaseAfterCheckedDrain() { features.removeAll() }
}
