// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer
import Testing

@testable import ProviderCore
@testable import ProviderCoreFoundation

/// Inkling 2 with thinking off: with `DARKBLOOM_INKLING_THINKING_OFF_SKIPS_THOUGHT`
/// on, the request's sampling bans the thought opener; everything else is
/// unchanged.
@Suite("Inkling 2 thinking off without a thought")
struct Inkling2ThinkingOffPolicyTests {
    static let type = Inkling2ModelIdentity.modelType
    static let on = [Inkling2ThinkingOffPolicy.environmentKey: "1"]

    static func request(_ json: String) throws -> (OpenAIChatCompletionRequest, ChatTemplateControls) {
        let body = Data((#"{"model":"m","messages":[{"role":"user","content":"hi"}]"# + json + "}").utf8)
        return (try ProviderLoop.decodeOpenAIRequest(body, modelType: type),
                ProviderLoop.extractChatTemplateControls(from: body))
    }

    @Test func theSwitchReachesTheLaunchAgent() {
        let key = Inkling2ThinkingOffPolicy.environmentKey
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "1"])[key] == "1")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }

    @Test func theSwitchIsOffByDefault() {
        #expect(!Inkling2ThinkingOffPolicy.skipsThought(environment: [:]))
        for (raw, on) in [("1", true), (" ON ", true), ("yes", true), ("true", true),
                          ("0", false), ("off", false), ("No", false), ("2", false), ("", false)] {
            #expect(Inkling2ThinkingOffPolicy.skipsThought(
                environment: [Inkling2ThinkingOffPolicy.environmentKey: raw]) == on, "\(raw)")
        }
    }

    /// Every form of thinking off bans the opener with the switch on; thinking
    /// on, an effort above none, another model or the switch off never does.
    @Test func onlyThinkingOffInklingWithTheSwitchOnBansTheThought() throws {
        for (json, off) in [
            ("", false), (#","reasoning_effort":"none""#, true), (#","reasoning_effort":"OFF""#, true),
            (#","reasoning_effort":"minimal""#, false), (#","reasoning":{"enabled":false}"#, true),
            (#","chat_template_kwargs":{"enable_thinking":false}"#, true),
            (#","reasoning":{"enabled":true},"reasoning_effort":"none""#, false),
        ] {
            let (decoded, controls) = try Self.request(json)
            #expect(Inkling2ThinkingOffPolicy.bansThought(decoded, controls: controls, modelType: Self.type,
                environment: Self.on) == off, "\(json)")
            #expect(!Inkling2ThinkingOffPolicy.bansThought(decoded, controls: controls, modelType: Self.type,
                environment: [:]), "\(json)")
            #expect(!Inkling2ThinkingOffPolicy.bansThought(decoded, controls: controls, modelType: "gemma4",
                environment: Self.on), "\(json)")
        }
    }

    @Test func theBanJoinsTheCallersOverrides() {
        let opener = 200_010
        // No caller overrides: the ban alone.
        #expect(Inkling2ThinkingOffPolicy.samplingOverrides(nil, bansThought: true, openerID: { opener })
            == EngineV2SamplingOverrides(logitBias: ["200010": -100], seed: nil))
        // The caller's seed and other biases stay; its bias on the opener is replaced.
        let caller = EngineV2SamplingOverrides(logitBias: ["7": 2.5, "200010": 5], seed: 42)
        #expect(Inkling2ThinkingOffPolicy.samplingOverrides(caller, bansThought: true, openerID: { opener })
            == EngineV2SamplingOverrides(logitBias: ["7": 2.5, "200010": -100], seed: 42))
    }

    @Test func withoutTheBanOrAnOpenerNothingChanges() {
        let caller = EngineV2SamplingOverrides(logitBias: ["7": 2.5], seed: 42)
        var asked = false
        #expect(Inkling2ThinkingOffPolicy.samplingOverrides(caller, bansThought: false,
            openerID: { asked = true; return 200_010 }) == caller)
        #expect(!asked, "the tokenizer is not consulted without a ban")
        #expect(Inkling2ThinkingOffPolicy.samplingOverrides(nil, bansThought: false, openerID: { 200_010 }) == nil)
        #expect(Inkling2ThinkingOffPolicy.samplingOverrides(caller, bansThought: true, openerID: { nil }) == caller)
        #expect(Inkling2ThinkingOffPolicy.samplingOverrides(caller, bansThought: true, openerID: { -1 }) == caller)
    }
}
