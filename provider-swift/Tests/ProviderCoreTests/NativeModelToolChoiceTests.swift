import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("Native model forced-tool enforcement")
struct NativeModelToolChoiceTests {
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
}
