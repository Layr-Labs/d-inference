// Copyright © 2026 Eigen Labs.
//
// A request names the pplx-decider pack by its short name or by its full
// id. Both resolve to the one advertised pack id. Other ids stay unchanged.

import Testing

@testable import ProviderCore

private func decider(id: String) -> ModelInfo {
    ModelInfo(
        id: id, modelType: "pplx_decider_qwen35", quantization: "4bit",
        sizeBytes: 1, estimatedMemoryGb: 1)
}

private let gptOSS = ModelInfo(
    id: "gpt-oss-20b", modelType: "gpt_oss", quantization: "4bit",
    sizeBytes: 1, estimatedMemoryGb: 1)

@Suite("pplx-decider model id resolution")
struct PplxDeciderModelIDResolutionTests {
    private let shortName = "pplx-decider-v1-27b"
    private let packID = EngineV2SupportedModels.pplxDeciderModelID

    @Test func shortNameResolvesToTheAdvertisedPack() {
        #expect(EngineV2SupportedModels.canonicalAdvertisedModelID(
            for: shortName, advertised: [gptOSS, decider(id: packID)]) == packID)
    }

    @Test func exactAdvertisedIDPassesThrough() {
        let advertised = [gptOSS, decider(id: packID)]
        #expect(EngineV2SupportedModels.canonicalAdvertisedModelID(
            for: packID, advertised: advertised) == packID)
        #expect(EngineV2SupportedModels.canonicalAdvertisedModelID(
            for: "gpt-oss-20b", advertised: advertised) == "gpt-oss-20b")
        #expect(EngineV2SupportedModels.canonicalAdvertisedModelID(
            for: shortName, advertised: [decider(id: shortName), decider(id: packID)]) == shortName)
    }

    @Test func shortNameWithNoAdvertisedDeciderStaysUnchanged() {
        #expect(EngineV2SupportedModels.canonicalAdvertisedModelID(
            for: shortName, advertised: [gptOSS]) == shortName)
        #expect(EngineV2SupportedModels.canonicalAdvertisedModelID(
            for: shortName, advertised: []) == shortName)
    }

    @Test func shortNameWithTwoAdvertisedDecidersStaysUnchanged() {
        // Only two listing ids exist and an exact match wins, so the two
        // candidates are two catalog rows for the same pack id.
        #expect(EngineV2SupportedModels.canonicalAdvertisedModelID(
            for: shortName, advertised: [decider(id: packID), decider(id: packID)]) == shortName)
        #expect(EngineV2SupportedModels.canonicalAdvertisedModelID(
            for: packID, advertised: [decider(id: shortName), decider(id: shortName)]) == packID)
    }

    @Test func unrelatedIDIsNeverRewritten() {
        #expect(EngineV2SupportedModels.canonicalAdvertisedModelID(
            for: "pplx-decider", advertised: [decider(id: packID)]) == "pplx-decider")
    }
}
