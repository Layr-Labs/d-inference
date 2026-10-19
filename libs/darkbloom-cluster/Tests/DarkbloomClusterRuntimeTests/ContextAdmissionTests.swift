import Foundation
import DarkbloomClusterProtocol
import Testing
@testable import DarkbloomClusterRuntime

// The model-independent pieces of long context: request limits from a declared
// context, one prefill frame's attention transient from a geometry, and the
// search for the largest context a gate admits. Pure: no model, no host sample.

@Suite("Context limits, attention transient and context search (pure)")
struct ContextAdmissionTests {
    /// The registered 27B's attention geometry, written out.
    private static func geometry(headDimension: Int = 256, queryHeads: Int = 24) throws -> QwenLongPrefillBudgetGeometry {
        try .init(layers: 64, fullAttentionInterval: 4, hiddenSize: 5120, queryHeads: queryHeads, kvHeads: 4,
            headDimension: headDimension, linearKeyHeads: 16, linearValueHeads: 48, linearKeyDimension: 128,
            linearValueDimension: 128, convolutionKernel: 4)
    }

    @Test func limitsAreTheProtocolBoundsCutToTheDeclaredContext() throws {
        let declared = try QwenResidentContextLimits(declaredContextTokens: 262_144)
        #expect(declared.maximumContextTokens == ClusterWorkerLimits.contextTokens)
        #expect(declared.maximumPromptTokens == ClusterWorkerLimits.promptTokens)
        #expect(declared.maximumOutputTokens == ClusterWorkerLimits.outputTokens)
        #expect(declared.maximumChunkTokens == QwenResidentContextLimits.chunkTokens)
        // A model that declares less is held to it, not to the protocol.
        let small = try QwenResidentContextLimits(declaredContextTokens: 4096)
        #expect(small.maximumContextTokens == 4096 && small.maximumPromptTokens == 4095 && small.maximumOutputTokens == 4095)
        #expect(try QwenResidentContextLimits(declaredContextTokens: 300).maximumChunkTokens == 299)
        for invalid in [Int.min, 0, 1, 1_048_577] {
            #expect(throws: (any Error).self) { _ = try QwenResidentContextLimits(declaredContextTokens: invalid) }
        }
        #expect(QwenResidentContextAdmission.minimumContextTokens(limits: declared) == 513)
        #expect(QwenResidentContextAdmission.minimumContextTokens(limits: try QwenResidentContextLimits(declaredContextTokens: 300)) == 300)
    }

    @Test func shortDeclaredContextStillConstrainsTheCombinedRequest() throws {
        let limits = try QwenResidentContextLimits(declaredContextTokens: 4096)
        let profile = try QwenLayerStageGenerationProfile(identifier: "short-context-regression",
            vocabularySize: 64, hiddenSize: 16, activationDType: "bfloat16",
            maximumPromptTokens: limits.maximumPromptTokens, maximumChunkTokens: limits.maximumChunkTokens,
            maximumOutputTokens: limits.maximumOutputTokens, maximumContextTokens: limits.maximumContextTokens)
        func request(_ output: Int) throws -> QwenLayerStageGenerationRequest {
            try .init(profile: profile, requestID: UUID(), promptTokenIDs: [1], chunkSize: 1,
                outputCount: output, stopTokenIDs: [])
        }
        #expect(try request(4095).maximumTokens == 4096)
        #expect(throws: (any Error).self) { _ = try request(4096) }
        #expect(throws: (any Error).self) {
            _ = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                promptTokenIDs: [1, 2], chunkSize: 2, outputCount: 4095, stopTokenIDs: [])
        }
    }

    @Test func theAttentionTransientIsOneFrameAtTheFullContext() throws {
        let g = try Self.geometry()
        // Head dimension 256 takes MLX's unfused path: float32 scores for 24
        // query heads, 512 queries and every key, beside a float32 output.
        let at30k = try QwenResidentPrefillTransient.bytes(geometry: g, stageHasAttention: true, chunkTokens: 512, contextTokens: 30_848)
        #expect(at30k == 24 * 512 * 30_848 * 4 + 24 * 512 * 256 * 4 && at30k == 1_528_823_808)
        #expect(try QwenResidentPrefillTransient.bytes(geometry: g, stageHasAttention: true, chunkTokens: 512, contextTokens: 5248) < at30k)
        // A frame never has more queries than the context it attends over.
        #expect(try QwenResidentPrefillTransient.bytes(geometry: g, stageHasAttention: true, chunkTokens: 512, contextTokens: 100)
            == 24 * 100 * 100 * 4 + 24 * 100 * 256 * 4)
        // A stage without an attention layer needs none; a fused head dimension only its output.
        #expect(try QwenResidentPrefillTransient.bytes(geometry: g, stageHasAttention: false, chunkTokens: 512, contextTokens: 30_848) == 0)
        for fused in [64, 128] {
            #expect(try QwenResidentPrefillTransient.bytes(geometry: Self.geometry(headDimension: fused, queryHeads: 32),
                stageHasAttention: true, chunkTokens: 512, contextTokens: 30_848) == 32 * 512 * fused * 4)
        }
        #expect(throws: (any Error).self) {
            _ = try QwenResidentPrefillTransient.bytes(geometry: g, stageHasAttention: true, chunkTokens: 0, contextTokens: 10)
        }
    }

    @Test func theLargestAdmissibleContextIsFoundByBinarySearch() throws {
        var calls = 0
        func below(_ limit: Int) -> (Int) throws -> Bool { { calls += 1; return $0 <= limit } }
        #expect(try QwenResidentContextAdmission.largest(minimum: 513, maximum: 32_768, admits: below(40_000)) == 32_768)
        calls = 0
        #expect(try QwenResidentContextAdmission.largest(minimum: 513, maximum: 32_768, admits: below(20_000)) == 20_000)
        #expect(calls <= 18)
        #expect(try QwenResidentContextAdmission.largest(minimum: 513, maximum: 32_768, admits: below(513)) == 513)
        #expect(try QwenResidentContextAdmission.largest(minimum: 513, maximum: 32_768, admits: below(512)) == nil)
        #expect(try QwenResidentContextAdmission.largest(minimum: 600, maximum: 600, admits: below(600)) == 600)
        #expect(throws: (any Error).self) { _ = try QwenResidentContextAdmission.largest(minimum: 10, maximum: 9, admits: below(5)) }
        #expect(throws: (any Error).self) { _ = try QwenResidentContextAdmission.largest(minimum: 0, maximum: 9, admits: below(5)) }
        // A refusal the gate cannot judge is not a smaller context: it propagates.
        struct Unjudged: Error {}
        #expect(throws: Unjudged.self) {
            _ = try QwenResidentContextAdmission.largest(minimum: 513, maximum: 32_768) { _ in throw Unjudged() }
        }
    }
}
