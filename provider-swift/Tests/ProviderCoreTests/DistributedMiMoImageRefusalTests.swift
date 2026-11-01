import Foundation
import Testing
import MLXLMCommon
@testable import ProviderCore

@Suite("MiMo cluster host envelope refusal (CPU)")
struct DistributedMiMoImageRefusalTests {
    @Test func textAndForeignProfilesRefuseBeforeReservation() throws {
        for id in ["foreign-text","registered_mimo_v26_flash_mopd_greedy_generation_v1"] {
            let profile = try DistributedResidentExecutionProfile(id:id,vocabularySize:152576,
                maxPromptTokens:1024,maxOutputTokens:128,maxContextTokens:2048,requestTimeout:.seconds(30))
            var request = CBv2Request(id:.init(42),promptTokens:[1,2],maxTokens:4)
            #expect(profile.refusal(for:request) == nil)
            request.mimoClusterImages = Data(#"{"images":[]}"#.utf8)
            #expect(profile.refusal(for:request) == .mediaUnsupported)
        }
    }
}
