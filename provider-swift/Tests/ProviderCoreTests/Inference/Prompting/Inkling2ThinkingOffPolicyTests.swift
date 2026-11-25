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
    /// A slot vocabulary that resolves only the thought opener's spelling.
    static let ids = ["<|content_thinking|>": 200_010]

    static func request(_ json: String) throws -> (OpenAIChatCompletionRequest, ChatTemplateControls) {
        let body = Data((#"{"model":"m","messages":[{"role":"user","content":"hi"}]"# + json + "}").utf8)
        return (try ProviderLoop.decodeOpenAIRequest(body, modelType: type),
                ProviderLoop.extractChatTemplateControls(from: body))
    }

    @Test func theSwitchReachesTheLaunchAgent() {
        let key = Inkling2ThinkingOffPolicy.environmentKey
        #expect(key == "DARKBLOOM_INKLING_THINKING_OFF_SKIPS_THOUGHT")
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "1"])[key] == "1")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }

    /// The scheduler reads the switch once per process (`switchedOn`); a
    /// task can set it around one request.
    @Test func theSwitchIsReadOnceAndCanBeSetPerTask() {
        Inkling2ThinkingOffPolicy.$switchedOn.withValue(true) {
            #expect(Inkling2ThinkingOffPolicy.switchedOn)
        }
        Inkling2ThinkingOffPolicy.$switchedOn.withValue(false) {
            #expect(!Inkling2ThinkingOffPolicy.switchedOn)
        }
    }

    @Test func theSwitchIsOffUnlessAnOnWordIsSet() {
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
                switchedOn: true) == off, "\(json)")
            #expect(!Inkling2ThinkingOffPolicy.bansThought(decoded, controls: controls, modelType: Self.type,
                switchedOn: false), "\(json)")
            #expect(!Inkling2ThinkingOffPolicy.bansThought(decoded, controls: controls, modelType: "gemma4",
                switchedOn: true), "\(json)")
        }
    }

    /// The ban is −100 on the id the slot's vocabulary gives the opener.
    @Test func theBanJoinsTheCallersOverrides() {
        // No caller overrides: the ban alone.
        #expect(Inkling2ThinkingOffPolicy.samplingOverrides(nil, bansThought: true, tokenToId: { Self.ids[$0] })
            == EngineV2SamplingOverrides(logitBias: ["200010": -100], seed: nil))
        // The caller's seed and other biases stay; its bias on the opener is replaced.
        let caller = EngineV2SamplingOverrides(logitBias: ["7": 2.5, "200010": 5], seed: 42)
        #expect(Inkling2ThinkingOffPolicy.samplingOverrides(caller, bansThought: true, tokenToId: { Self.ids[$0] })
            == EngineV2SamplingOverrides(logitBias: ["7": 2.5, "200010": -100], seed: 42))
    }

    /// A caller bias on the opener under another spelling of its id, one the
    /// engine reads as that id, is dropped too, so it cannot outlast the ban.
    @Test func theBanReplacesEverySpellingOfTheOpenersId() {
        for spelling in [" 200010", "+200010", "0200010"] {
            #expect(EngineV2Translation.parseLogitBias([spelling: 1]) == [200_010: 1], "\(spelling)")
        }
        let caller = EngineV2SamplingOverrides(logitBias: [" 200010": 5, "+200010": 6, "0200010": 7, "7": 2.5],
                                               seed: nil)
        #expect(Inkling2ThinkingOffPolicy.samplingOverrides(caller, bansThought: true, tokenToId: { Self.ids[$0] })
            == EngineV2SamplingOverrides(logitBias: ["7": 2.5, "200010": -100], seed: nil))
    }

    /// Without a sealed-body overlay (the local API) the ban joins the
    /// request's own `logit_bias` and `seed`; an overlay is the base when
    /// present. Without a ban the overlay passes unchanged, nil included, and
    /// the vocabulary is not consulted.
    @Test func requestSamplingStartsFromTheOverlayOrTheRequest() throws {
        let (request, _) = try Self.request(#","logit_bias":{"7":2.5},"seed":9"#)
        #expect(Inkling2ThinkingOffPolicy.requestSampling(overlay: nil, request: request, bansThought: true,
            tokenToId: { Self.ids[$0] }) == EngineV2SamplingOverrides(logitBias: ["7": 2.5, "200010": -100], seed: 9))
        let overlay = EngineV2SamplingOverrides(logitBias: ["8": 1], seed: 42)
        #expect(Inkling2ThinkingOffPolicy.requestSampling(overlay: overlay, request: request, bansThought: true,
            tokenToId: { Self.ids[$0] }) == EngineV2SamplingOverrides(logitBias: ["8": 1, "200010": -100], seed: 42))
        #expect(Inkling2ThinkingOffPolicy.requestSampling(overlay: overlay, request: request, bansThought: false,
            tokenToId: { Self.ids[$0] }) == overlay)
        var asked = false
        let unbanned = Inkling2ThinkingOffPolicy.requestSampling(overlay: nil, request: request, bansThought: false,
            tokenToId: { asked = true; return Self.ids[$0] })
        #expect(unbanned == nil)
        #expect(!asked, "the tokenizer is not consulted without a ban")
    }

    @Test func withoutTheBanOrAnOpenerNothingChanges() {
        let caller = EngineV2SamplingOverrides(logitBias: ["7": 2.5], seed: 42)
        var asked = false
        let unbanned = Inkling2ThinkingOffPolicy.samplingOverrides(caller, bansThought: false,
            tokenToId: { asked = true; return Self.ids[$0] })
        #expect(unbanned == caller)
        #expect(!asked, "the tokenizer is not consulted without a ban")
        #expect(Inkling2ThinkingOffPolicy.samplingOverrides(nil, bansThought: false, tokenToId: { Self.ids[$0] })
            == nil)
        #expect(Inkling2ThinkingOffPolicy.samplingOverrides(caller, bansThought: true, tokenToId: { _ in nil })
            == caller)
        #expect(Inkling2ThinkingOffPolicy.samplingOverrides(caller, bansThought: true, tokenToId: { _ in -1 })
            == caller)
    }
}
