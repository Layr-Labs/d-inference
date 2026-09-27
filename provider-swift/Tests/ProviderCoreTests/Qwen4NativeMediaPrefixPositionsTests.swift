// Copyright © 2026 Eigen Labs.

import MLX
import MLXLMCommon
import Testing
@testable import MLXVLM
@testable import ProviderCore

@Suite("Qwen4 native media position append identity")
struct Qwen4NativeMediaPrefixPositionsTests {
    @Test("the native Qwen4 position seam preserves normalized image/video/mixed prefixes", arguments: [0, 1, 2])
    func nativeAppend(kind: Int) throws {
        let image = 248056, video = 248057, start = 248053, end = 248054
        let seam = Qwen35VisionSeamConfiguration(
            imagePlaceholderTokenId: image, videoPlaceholderTokenId: video,
            imagePositionTokenId: image, videoPositionTokenId: video,
            visionStartTokenId: start, visionEndTokenId: end,
            spatialMergeSize: 2, temporalPatchSize: 2, attention: .causal)
        let first = kind == 1 ? video : image
        var tokens = [7, start, first, first, first, first, end, 8]
        var spans = [CBv2ImageSpan(tokenOffset: 2, length: 4)]
        var kinds: [EngineV2VisionPrefill.SpanKind] = [kind == 1 ? .video : .image]
        if kind == 2 {
            tokens += [start, video, video, video, video, end, 9]
            spans.append(.init(tokenOffset: 9, length: 4))
            kinds.append(.video)
        }
        let imageGrids: [THW]? = kind == 1 ? nil : [THW(1, 4, 4)]
        let videoGrids: [THW]? = kind == 0 ? nil : [THW(1, 4, 4)]
        // This is the same stateless seam called by native Qwen4Exp.positionResult;
        // no alternate model, fake delta or hand-built position suffix is used.
        func state(_ values: [Int]) throws -> CBv2PositionState {
            let result = try QwenVisionSeamSupport.positionResult(
                tokens: MLXArray(values.map(Int32.init)), imageGrids: imageGrids,
                videoGrids: videoGrids, attentionMask: nil, seam: seam)
            return CBv2PositionState(promptPositionIds: result.promptPositionIds,
                                    decodeDeltas: result.decodeState.deltas)
        }
        let original = try state(tokens)
        let appended = try state(tokens + [17, 18, 19, 20, 21])
        #expect(original.decodeDeltas == appended.decodeDeltas)
        #expect(original.promptPositionIds.asArray(Int32.self)
            == appended.promptSlice(0 ..< tokens.count).asArray(Int32.self))
        let embeddings = spans.map { MLXArray.zeros([1, $0.length, 2]) }
        func identity(_ position: CBv2PositionState, canonical: Bool) throws -> CBv2HybridPrefixIdentity {
            try EngineV2HybridPrefixIdentityBuilder.make(
                spans: spans, spanKinds: kinds, embeddings: embeddings, deepstackEmbeddings: [],
                attention: .causal, positionState: position, canonicalQwen4TextTail: canonical)
        }
        let normalized = try identity(original, canonical: true)
        #expect(try normalized == identity(appended, canonical: true))
        #expect(try normalized != identity(original, canonical: false))
        #expect(try identity(original, canonical: false) != identity(appended, canonical: false))
    }
}
