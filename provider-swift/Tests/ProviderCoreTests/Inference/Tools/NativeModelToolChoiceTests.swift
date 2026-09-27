import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("Native model forced-tool enforcement")
struct NativeModelToolChoiceTests {
    @Test func diffusionUsesItsNativeFrameAndDoesNotBroadenGemmaARGrammar() throws {
        let context = ChatTemplateFixContext(modelId: "native-diffusion", modelType: "diffusion_gemma")
        #expect(!Gemma4TemplateFix.applies(to: context))
        for mode: ToolConstraintMode in [.required, .named("get_weather")] {
            let strategy = try ToolChoiceEnforcementPolicy.forcedStrategy(mode: mode, modelContext: context)
            #expect(strategy == .structuredPostValidation)
            try ToolChoiceEnforcementPolicy.validateParser(.gemma, strategy: strategy, modelContext: context)
            for wrong: ToolCallFormat in [.xmlFunction, .qwen35, .nemotron, .json] {
                #expect(throws: (any Error).self) {
                    try ToolChoiceEnforcementPolicy.validateParser(wrong, strategy: strategy, modelContext: context)
                }
            }
        }
        #expect(!ToolChoiceEnforcementPolicy.nativeStructuredTarget(
            .init(modelId: "looks-like-diffusion_gemma", modelType: "llama")))
    }

    @Test func bonsaiUsesNativeQwenFramingWithoutAdvertisingOtherArtifacts() throws {
        let context = ChatTemplateFixContext(
            modelId: EngineV2SupportedModels.bonsai2ModelID, modelType: "prism_hadamard_qwen35")
        #expect(Qwen35TemplateFix.applies(to: context))
        #expect(ToolChoiceEnforcementPolicy.nativeStructuredTarget(context))
        #expect(ToolChoiceEnforcementPolicy.supportsForcedMedia(context: context, nativeWrapperLoaded: true))
        #expect(!ToolChoiceEnforcementPolicy.supportsForcedMedia(context: context, nativeWrapperLoaded: false))
        #expect(!ToolChoiceEnforcementPolicy.supportsForcedMedia(
            context: .init(modelId: "unqualified/Bonsai", modelType: "prism_hadamard_qwen35"), nativeWrapperLoaded: true))
        #expect(!ToolChoiceEnforcementPolicy.supportsForcedMedia(
            context: .init(modelId: "owned-flash-next", modelType: "qwen4_exp"), nativeWrapperLoaded: true))
        for mode: ToolConstraintMode in [.required, .named("weather")] {
            let strategy = try ToolChoiceEnforcementPolicy.forcedStrategy(mode: mode, modelContext: context)
            #expect(strategy == .structuredPostValidation)
            try ToolChoiceEnforcementPolicy.validateParser(.qwen35, strategy: strategy, modelContext: context)
            #expect(throws: (any Error).self) {
                try ToolChoiceEnforcementPolicy.validateParser(.nemotron, strategy: strategy, modelContext: context)
            }
        }
        #expect(!ToolChoiceEnforcementPolicy.nativeStructuredTarget(
            .init(modelId: "unqualified/Bonsai", modelType: "prism_hadamard_qwen35")))
    }

    @Test func onlyFramingWhitespaceIsIgnorableInForcedMode() {
        #expect(ToolChoiceEnforcementPolicy.isFramingWhitespace("\n\n \t\r"))
        #expect(!ToolChoiceEnforcementPolicy.isFramingWhitespace("Let me think"))
        #expect(!ToolChoiceEnforcementPolicy.isFramingWhitespace("<think>"))
        #expect(!ToolChoiceEnforcementPolicy.isFramingWhitespace("\u{200B}"))
    }

    @Test func nativeFamiliesUseWithheldSchemaValidatedCalls() throws {
        let contexts = [
            ChatTemplateFixContext(modelId: EngineV2SupportedModels.nemotron35LightningModelID, modelType: "nemotron_h"),
        ]
        for context in contexts {
            for mode: ToolConstraintMode in [.required, .named("add")] {
                let strategy = try ToolChoiceEnforcementPolicy.forcedStrategy(mode: mode, modelContext: context)
                #expect(strategy == .structuredPostValidation)
                try ToolChoiceEnforcementPolicy.validateParser(.xmlFunction, strategy: strategy)
                #expect(throws: (any Error).self) {
                    try ToolChoiceEnforcementPolicy.validateParser(.qwen35, strategy: strategy)
                }
                try ToolChoiceEnforcementPolicy.validateParser(.nemotron, strategy: strategy)
                #expect(throws: (any Error).self) {
                    try ToolChoiceEnforcementPolicy.validateParser(.json, strategy: strategy)
                }
            }
        }
    }

    @Test func unqualifiedVariantsRemainRefusedAndAutoIsUnchanged() throws {
        let context = ChatTemplateFixContext(modelId: "unqualified-nemotron", modelType: "nemotron_h")
        #expect(throws: (any Error).self) {
            try ToolChoiceEnforcementPolicy.forcedStrategy(mode: .required, modelContext: context)
        }
        #expect(try ToolChoiceEnforcementPolicy.forcedStrategy(mode: .auto, modelContext: context) == .none)
        #expect(try ToolChoiceEnforcementPolicy.forcedStrategy(mode: .none, modelContext: context) == .none)
    }

    @Test func nativeQwenParserAcceptanceDoesNotBroadenOtherFamilies() throws {
        for type in ["qwen4_exp", "qwen4_exp_text"] {
            let context = ChatTemplateFixContext(modelId: "owned-flash-next", modelType: type)
            for mode: ToolConstraintMode in [.required, .named("add")] {
                let strategy = try ToolChoiceEnforcementPolicy.forcedStrategy(mode: mode, modelContext: context)
                #expect(strategy == .structuredPostValidation)
                for format: ToolCallFormat in [.xmlFunction, .qwen35] {
                    try ToolChoiceEnforcementPolicy.validateParser(format, strategy: strategy, modelContext: context)
                }
                for format: ToolCallFormat in [.json, .nemotron, .gemma] {
                    #expect(throws: (any Error).self) {
                        try ToolChoiceEnforcementPolicy.validateParser(format, strategy: strategy, modelContext: context)
                    }
                }
            }
        }
        let unrelated = ChatTemplateFixContext(modelId: "looks-like-qwen4_exp", modelType: "llama")
        #expect(!ToolChoiceEnforcementPolicy.nativeStructuredTarget(unrelated))
        let nemotron = ChatTemplateFixContext(
            modelId: EngineV2SupportedModels.nemotron35LightningModelID, modelType: "nemotron_h")
        #expect(throws: (any Error).self) {
            try ToolChoiceEnforcementPolicy.validateParser(
                .qwen35, strategy: .structuredPostValidation, modelContext: nemotron)
        }
    }
}
