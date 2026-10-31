import Foundation
import Testing
@testable import DarkbloomClusterRuntime

/// Fixed pre-image-proposal protocol vectors. No media decoder, MLX array or GPU.
@Suite("Generation nil-media legacy goldens (CPU)")
struct GenerationNilMediaGoldenTests {
    @Test func legacyProfileAndGreedyRequestBytesStayIdenticalWithMediaAbsent() throws {
        let profile = try QwenLayerStageGenerationProfile(identifier:"qwen35-fixture",vocabularySize:64,
            hiddenSize:32,activationDType:"bfloat16",maximumPromptTokens:128,maximumChunkTokens:16,
            maximumOutputTokens:8,maximumContextTokens:256)
        #expect(profile.fingerprint == "ac2fa4b057570ac9e3ebe5dd43314539ba58e7df2fc02729c02c808cf36789b7")
        let expected = #"{"activationDType":"bfloat16","fingerprint":"ac2fa4b057570ac9e3ebe5dd43314539ba58e7df2fc02729c02c808cf36789b7","hiddenSize":32,"identifier":"qwen35-fixture","maximumChunkTokens":16,"maximumContextTokens":256,"maximumOutputTokens":8,"maximumPromptTokens":128,"vocabularySize":64}"#
        #expect(try canonicalJSONData(profile) == Data(expected.utf8))
        let id = UUID(uuidString:"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let legacy = try QwenLayerStageGenerationRequest(profile:profile,requestID:id,promptTokenIDs:Array(0..<10),
            chunkSize:4,outputCount:3,stopTokenIDs:[63,62])
        let explicitNil = try QwenLayerStageGenerationRequest(profile:profile,requestID:id,promptTokenIDs:Array(0..<10),
            chunkSize:4,outputCount:3,stopTokenIDs:[62,63],mimoImages:nil)
        #expect(legacy.mimoImages == nil && explicitNil.mimoImages == nil)
        #expect(legacy.fingerprint == "09ce1dd913d93b06c56728c075932522984a84b6e4a9bc51ce71f2ed6dd681ba")
        #expect(explicitNil.fingerprint == legacy.fingerprint)
        #expect(try legacy.planned(reusedPrefix:1,splitFinalToken:true).fingerprint == legacy.fingerprint)
    }
}
