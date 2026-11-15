// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// The rules that follow Muse Glimmer's wire protocol: tool choice, parser
/// selection, stop tokens and where client stop strings apply.
@Suite("Muse Glimmer protocol policy")
struct MuseGlimmerProtocolPolicyTests {
    private static let ids = [MuseGlimmerModelPolicy.catalogModelID, MuseGlimmerModelPolicy.localModelID]
    private static let type = MuseGlimmerModelPolicy.modelType
    private static let lookalikes = ["meta-models/Muse-Glimmer-30B", "muse-glimmer-30b-bf16", "Muse-Glimmer-30B"]

    private func model(_ id: String, _ type: String?) -> ModelInfo {
        ModelInfo(id: id, modelType: type, sizeBytes: 1, estimatedMemoryGb: 1)
    }

    @Test("required and named tool choice is advertised for the exact identity only")
    func toolChoiceCapability() throws {
        for id in Self.ids {
            #expect(ToolChoiceEnforcementPolicy.advertisesCapability(for: model(id, Self.type)))
            #expect(!ToolChoiceEnforcementPolicy.advertisesCapability(for: model(id, "llama")))
        }
        for id in Self.lookalikes {
            #expect(!ToolChoiceEnforcementPolicy.advertisesCapability(for: model(id, Self.type)))
        }
        let context = ChatTemplateFixContext(modelId: Self.ids[0], modelType: Self.type)
        for mode in [ToolConstraintMode.required, .named("get_weather")] {
            #expect(try ToolChoiceEnforcementPolicy.forcedStrategy(mode: mode, modelContext: context)
                == .structuredPostValidation)
        }
        #expect(try ToolChoiceEnforcementPolicy.forcedStrategy(mode: .auto, modelContext: context) == .none)
        try ToolChoiceEnforcementPolicy.validateParser(.atem, strategy: .structuredPostValidation, modelContext: context)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolChoiceEnforcementPolicy.validateParser(
                .json, strategy: .structuredPostValidation, modelContext: context)
        }
        #expect(ToolChoiceEnforcementPolicy.usesNativeTextChannels(context))
        // It is not a think-tag family: its channels have their own splitter.
        #expect(!ToolChoiceEnforcementPolicy.nativeStructuredTarget(context))
    }

    @Test("no think-tag parser rereads its channels")
    func reasoningParser() {
        #expect(ProviderLoop.inferReasoningParser(for: Self.type) == .none)
        #expect(ProviderLoop.inferReasoningParser(for: "MUSE_GLIMMER") == .none)
        #expect(ReasoningStopScope.scope(reasoningParser: ReasoningParserFormat.none, reasoningPrefix: nil,
                                         parsesToolCalls: true) == nil)
    }

    @Test("end of turn and end of text stop generation; end of message never does")
    func stopTokens() {
        let vocabulary = ["<|end_of_text|>": 200_001, "<|eom|>": 200_007, "<|eot|>": 200_008,
                          "<|start|>": 200_022, "<|message|>": 200_023]
        // The artifact's generation_config.json declares exactly these two.
        let declared: Set<Int> = [200_001, 200_008]
        for id in Self.ids {
            #expect(ModelEOSPolicy.effectiveEOSTokenIds(
                modelId: id, modelType: Self.type, base: declared) { vocabulary[$0] } == declared)
            // An artifact that left one out, or wrongly listed end of message.
            #expect(ModelEOSPolicy.effectiveEOSTokenIds(
                modelId: id, modelType: Self.type, base: [200_001, 200_007]) { vocabulary[$0] } == declared)
            #expect(ModelEOSPolicy.effectiveEOSTokenIds(
                modelId: id, modelType: Self.type, base: []) { vocabulary[$0] } == declared)
        }
        // Another family's stop set is untouched.
        #expect(ModelEOSPolicy.effectiveEOSTokenIds(
            modelId: "other", modelType: "llama", base: [200_007]) { vocabulary[$0] } == [200_007])
    }

    @Test("client stop strings match on the answer channel only")
    func stopStringScope() {
        let scope = ModelEOSPolicy.stopStringScope(modelId: Self.ids[0], modelType: Self.type)
        #expect(scope == MuseGlimmerTemplateFix.answerStopScope)
        func run(_ output: String) -> (text: String, stopped: Bool) {
            let holdback = StopHoldback(stopStrings: ["END"], scope: scope)
            let scan = holdback.ingest(output)
            return (scan.stopped ? scan.text : scan.text + holdback.flush(), scan.stopped)
        }
        let reasoning = " to=self<|message|>plan END here<|eom|><|start|>assistant"
        let call = " to=f<|message|><atem:function_calls>\n<atem:invoke name=\"f\">\n"
            + "<atem:parameter name=\"x\">END</atem:parameter>\n</atem:invoke>\n</atem:function_calls>"
        #expect(run(reasoning + call) == (reasoning + call, false))
        let answered = run(reasoning + " to=user<|message|>Answer END tail")
        #expect(answered.stopped)
        #expect(answered.text == reasoning + " to=user<|message|>Answer ")
    }
}
