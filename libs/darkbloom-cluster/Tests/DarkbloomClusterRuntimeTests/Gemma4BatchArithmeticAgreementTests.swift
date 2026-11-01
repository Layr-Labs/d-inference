import Testing
@testable import DarkbloomClusterRuntime

struct Gemma4BatchArithmeticAgreementTests {
    @Test func onlyRegisteredGemmaMultiLaneLoadsGainTheMarker() {
        for model in Gemma4RegisteredModel.allCases {
            #expect(Gemma4BatchArithmeticAgreement.fields(runtimeModelID: model.rawValue, lanes: 1).isEmpty)
            for lanes in 2...8 {
                #expect(Gemma4BatchArithmeticAgreement.fields(runtimeModelID: model.rawValue, lanes: lanes)
                    == ["gemma4-batch-row-m1-v1", "lanes=\(lanes)", "expert-rows=singleton"])
            }
        }
        for model in ["registered_qwen3_8_27b", "registered_gpt_oss_120b", "registered_glm_5_3_flash", "unknown"] {
            for lanes in 1...8 {
                #expect(Gemma4BatchArithmeticAgreement.fields(runtimeModelID: model, lanes: lanes).isEmpty)
            }
        }
    }
}
