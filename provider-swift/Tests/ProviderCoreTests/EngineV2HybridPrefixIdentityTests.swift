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
        positionState: CBv2PositionState? = nil
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
            positionState: positionState ?? positions())
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
}
