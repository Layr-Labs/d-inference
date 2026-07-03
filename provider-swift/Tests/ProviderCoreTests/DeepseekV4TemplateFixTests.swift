import Testing

@testable import ProviderCore

@Suite("DeepseekV4TemplateFix.applies")
struct DeepseekV4TemplateFixTests {
    @Test("matches via modelType, with common separator/casing variants")
    func matchesModelType() {
        #expect(DeepseekV4TemplateFix.applies(to: .init(modelType: "deepseek_v4")))
        #expect(DeepseekV4TemplateFix.applies(to: .init(modelType: "deepseek-v4")))
        #expect(DeepseekV4TemplateFix.applies(to: .init(modelType: "DeepSeek_V4")))
        #expect(DeepseekV4TemplateFix.applies(to: .init(modelType: "deepseek_v4_flash")))
    }

    @Test("falls back to modelId when modelType is unavailable (e.g. /apply-template)")
    func matchesModelIdFallback() {
        #expect(
            DeepseekV4TemplateFix.applies(
                to: .init(modelId: "mlx-community/DeepSeek-V4-Flash-4bit")))
        #expect(!DeepseekV4TemplateFix.applies(to: .init(modelId: "mlx-community/Qwen3-0.6B-4bit")))
    }

    @Test("does not collapse DeepSeek-R1/V3 (a different, plain <think> family) onto DSML")
    func doesNotMatchOtherDeepseekFamilies() {
        #expect(!DeepseekV4TemplateFix.applies(to: .init(modelType: "deepseek")))
        #expect(!DeepseekV4TemplateFix.applies(to: .init(modelType: "deepseek_r1")))
        #expect(!DeepseekV4TemplateFix.applies(to: .init(modelType: "deepseek_v3")))
    }

    @Test("neither hint present")
    func matchesNeither() {
        #expect(!DeepseekV4TemplateFix.applies(to: .init()))
        #expect(!DeepseekV4TemplateFix.applies(to: .init(modelId: "some/other-model")))
    }
}
