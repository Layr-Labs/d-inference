import Foundation
import Testing
@testable import ProviderCore

@Test func imageWorkProfileIsOptionalBoundedAndDoesNotCreditPromptTokens() throws {
    let profile = RequestProfileBuilder()
    profile.set(.promptTokens, 500)
    let cold = profile.wireObject()
    #expect(cold.visionFeatureCacheHits == nil)
    #expect(cold.visionEncoderImages == nil)
    profile.update { fields, _ in
        fields.set(.visionFeatureCacheHits, 2)
        fields.set(.visionEncoderImages, 0)
    }
    let warm = profile.wireObject()
    #expect(warm.promptTokens == 500)
    #expect(warm.visionFeatureCacheHits == 2)
    #expect(warm.visionEncoderImages == 0)
    let bytes = try JSONEncoder().encode(warm)
    let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(json["vision_feature_cache_hits"] as? Int == 2)
    #expect(json["vision_encoder_images"] as? Int == 0)
    #expect(json["cached_tokens"] == nil)
    #expect(try JSONDecoder().decode(InferenceProfile.self, from: bytes) == warm)
    profile.set(.visionFeatureCacheHits, Int64.max)
    profile.set(.visionEncoderImages, -1)
    #expect(profile.wireObject().visionFeatureCacheHits == 1024)
    #expect(profile.wireObject().visionEncoderImages == 0)
}

@Test func saturatedProfileIncludesImageCountersWithinExisting4096ByteCap() throws {
    let full = fullInferenceProfile()
    #expect(full.visionFeatureCacheHits == 1024)
    #expect(full.visionEncoderImages == 1024)
    #expect(full.saturatedToWireRanges() == full)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(full)
    #expect(data.count <= 4096)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["vision_feature_cache_hits"] as? Int == 1024)
    #expect(json["vision_encoder_images"] as? Int == 1024)
    print("fully populated bounded profile bytes: \(data.count)")
}
