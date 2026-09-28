// Copyright © 2026 Eigen Labs.

import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("EngineV2 multimodal hybrid-prefix identity")
struct EngineV2HybridPrefixIdentityTests {
    private let spans = [
        CBv2ImageSpan(tokenOffset: 1, length: 1),
        CBv2ImageSpan(tokenOffset: 3, length: 1),
    ]

    private func embedding(_ values: [Float]) -> MLXArray {
        MLXArray(values).reshaped([1, 1, values.count])
    }

    private func positions(_ tail: Int32 = 3) -> CBv2PositionState {
        CBv2PositionState(
            promptPositionIds: MLXArray([
                Int32(0), 1, 2, tail,
                0, 1, 2, tail,
                0, 1, 2, tail,
            ]).reshaped([3, 1, 4]),
            decodeDeltas: [7])
    }

    private func identity(
        kinds: [EngineV2VisionPrefill.SpanKind] = [.image, .video],
        embeddings: [MLXArray]? = nil,
        deepstack: [[MLXArray]] = [],
        attention: CBv2MultimodalAttention = .causal,
        positionState: CBv2PositionState? = nil,
        canonicalQwen4TextTail: Bool = false
    ) throws -> CBv2HybridPrefixIdentity {
        try EngineV2HybridPrefixIdentityBuilder.make(
            spans: spans,
            spanKinds: kinds,
            embeddings: embeddings ?? [
                embedding([1, 2]),
                embedding([3, 4]),
            ],
            deepstackEmbeddings: deepstack,
            attention: attention,
            positionState: positionState ?? positions(),
            canonicalQwen4TextTail: canonicalQwen4TextTail)
    }

    @Test("same evaluated media state produces the same opaque digest")
    func deterministic() throws {
        let first = try identity()
        let second = try identity()

        #expect(first == second)
        #expect(first.digest.count == 32)
    }

    @Test("projected media content and order partition cache identity")
    func contentAndOrderPartition() throws {
        let baseline = try identity()
        let changedContent = try identity(embeddings: [
            embedding([1, 2]),
            embedding([3, 5]),
        ])
        let reordered = try identity(
            kinds: [.video, .image],
            embeddings: [
                embedding([3, 4]),
                embedding([1, 2]),
            ])

        #expect(changedContent != baseline)
        #expect(reordered != baseline)
    }

    @Test("mRoPE, attention, and DeepStack state partition cache identity")
    func positionAndExecutionContractPartition() throws {
        let baseline = try identity()
        let changedPosition = try identity(positionState: positions(4))
        let changedAttention = try identity(attention: .bidirectionalSpans)
        let changedDeepstack = try identity(deepstack: [[
            embedding([5, 6]),
            embedding([7, 8]),
        ]])

        #expect(changedPosition != baseline)
        #expect(changedAttention != baseline)
        #expect(changedDeepstack != baseline)
    }

    @Test("dtype, decode delta and invalid geometry remain explicit")
    func dtypeDeltaAndGeometry() throws {
        let baseline = try identity()
        let changedDType = try identity(embeddings: [
            embedding([1,2]).asType(.float16), embedding([3,4]).asType(.float16),
        ])
        #expect(changedDType != baseline)
        let original = positions()
        let changedDelta = CBv2PositionState(promptPositionIds: original.promptPositionIds, decodeDeltas: [-7])
        let changedDeltaIdentity = try identity(positionState: changedDelta)
        #expect(changedDeltaIdentity != baseline)
        #expect(throws: EngineV2HybridPrefixIdentityBuilder.Failure.invalidGeometry) {
            try identity(kinds: [.image])
        }
        #expect(throws: EngineV2HybridPrefixIdentityBuilder.Failure.invalidGeometry) {
            try identity(embeddings: [embedding([1,2]).reshaped([1,2,1]), embedding([3,4])])
        }
    }

    private func canonicalPositions(length: Int, delta: Int32 = -2, dtype: DType = .int32) -> CBv2PositionState {
        let values: [Int64] = (0 ..< 3).flatMap { _ in
            (0 ..< length).map { index in index < 4 ? Int64(index) : Int64(index) + Int64(delta) }
        }
        return CBv2PositionState(
            promptPositionIds: MLXArray(values).reshaped([3, 1, length]).asType(dtype),
            decodeDeltas: [delta])
    }

    @Test("owned Qwen4 canonical text append preserves prefix identity only when opted in")
    func canonicalAppend() throws {
        let short = canonicalPositions(length: 8)
        let long = canonicalPositions(length: 23)
        let first = try identity(positionState: short, canonicalQwen4TextTail: true)
        let appended = try identity(positionState: long, canonicalQwen4TextTail: true)
        #expect(first == appended)
        #expect(try identity(positionState: short) != identity(positionState: long))
        #expect(try first != identity(positionState: short))
    }

    @Test("changed tail positions preserve full conservative identity")
    func noncanonicalAppendFallback() throws {
        let original = canonicalPositions(length: 12)
        let baseline = try identity(positionState: original, canonicalQwen4TextTail: true)
        for axis in 0 ..< 3 {
            for offset in 4 ..< 12 {
                var values = original.promptPositionIds.asArray(Int32.self)
                values[axis * 12 + offset] += 1
                let changed = CBv2PositionState(
                    promptPositionIds: MLXArray(values).reshaped([3, 1, 12]),
                    decodeDeltas: original.decodeDeltas)
                let optimized = try identity(positionState: changed, canonicalQwen4TextTail: true)
                #expect(optimized != baseline)
                #expect(try optimized == identity(positionState: changed))
            }
        }
    }

    @Test("canonical binding retains media, position, dtype, delta and execution negatives")
    func canonicalBindingNegatives() throws {
        let state = canonicalPositions(length: 12)
        let baseline = try identity(positionState: state, canonicalQwen4TextTail: true)
        let changedDtype = try identity(
            positionState: canonicalPositions(length: 12, dtype: .int64), canonicalQwen4TextTail: true)
        let changedDelta = try identity(
            positionState: canonicalPositions(length: 12, delta: -1), canonicalQwen4TextTail: true)
        let changedMedia = try identity(embeddings: [embedding([1, 2]), embedding([3, 5])],
            positionState: state, canonicalQwen4TextTail: true)
        let changedKind = try identity(kinds: [.video, .image],
            positionState: state, canonicalQwen4TextTail: true)
        let changedDeepstack = try identity(deepstack: [[embedding([5, 6]), embedding([7, 8])]],
            positionState: state, canonicalQwen4TextTail: true)
        var values = state.promptPositionIds.asArray(Int32.self)
        values[3] += 1
        let changedPrefix = try identity(positionState: CBv2PositionState(
            promptPositionIds: MLXArray(values).reshaped([3, 1, 12]), decodeDeltas: state.decodeDeltas),
            canonicalQwen4TextTail: true)
        for changed in [changedDtype, changedDelta, changedMedia, changedKind, changedDeepstack, changedPrefix] {
            #expect(changed != baseline)
        }
        let noncausal = try identity(attention: .bidirectionalSpans, positionState: state,
            canonicalQwen4TextTail: true)
        #expect(try noncausal == identity(attention: .bidirectionalSpans, positionState: state))
        #expect(noncausal != baseline)
        let floats = canonicalPositions(length: 12, dtype: .float32)
        #expect(try identity(positionState: floats, canonicalQwen4TextTail: true)
            == identity(positionState: floats))
    }
}
