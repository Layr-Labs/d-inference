// Copyright © 2026 Eigen Labs.

import Foundation
import Testing

@testable import ProviderCore

/// The admission path decodes the request and its body extensions together;
/// every read must equal the separate `decodeOpenAIRequest` and per-field
/// extractor calls, including repaired, malformed and rejected bodies.
@Suite("Merged inbound chat-request decode")
struct InboundChatRequestDecodeTests {
    static let bodies: [String] = [
        #"{"model":"m","messages":[{"role":"user","content":"hi"}],"temperature":0.7}"#,
        #"{"model":"m","messages":[{"role":"user","content":"x"}],"logprobs":true,"top_logprobs":3,"seed":42,"logit_bias":{"11":-100,"12":2.5}}"#,
        #"{"model":"m","messages":[{"role":"user","content":"x"}],"logprobs":false,"top_logprobs":3,"logit_bias":{}}"#,
        #"{"model":"m","messages":[{"role":"user","content":"x"}],"logprobs":"yes","top_logprobs":"many","reasoning_effort":5,"preserve_thinking":"x"}"#,
        #"{"model":"m","messages":[{"role":"user","content":"x"}],"seed":18446744073709551615,"logit_bias":{"5":1}}"#,
        #"{"model":"m","messages":[{"role":"user","content":"x"}],"reasoning_effort":" high ","enable_thinking":false,"preserve_thinking":true}"#,
        #"{"model":"m","messages":[{"role":"user","content":"x"}],"chat_template_kwargs":{"enable_thinking":true},"_darkbloom_prompt_date":"2026-10-21"}"#,
        #"{"model":"m","messages":[{"role":"user","content":"x"}],"enable_thinking":"no","chat_template_kwargs":{"enable_thinking":false}}"#,
        // Repaired bodies: typeless tool schemas, legacy function calls, role aliases.
        #"{"model":"m","messages":[{"role":"user","content":"x"}],"seed":7,"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"a":{"enum":["x"]}}}}}]}"#,
        #"{"model":"m","messages":[{"role":"user","content":"x"},{"role":"assistant","content":null,"function_call":{"name":"f","arguments":"{}"}},{"role":"function","name":"f","content":"1"}],"logprobs":true}"#,
        #"{"model":"m","messages":[{"role":"developer","content":"be brief"},{"role":"user","content":"x"}],"stop":"END","seed":3}"#,
        #"{"model":"m","messages":[{"role":"user","content":"search"}],"tools":[{"type":"web_search"}],"top_logprobs":2,"logprobs":true}"#,
    ]

    static let invalidBodies: [String] = [
        "not json",
        #"["model"]"#,
        #"{"model":"m"}"#,
        #"{"model":"m","messages":[{"role":"wizard","content":"x"}]}"#,
        // The upstream request types `seed` and `logit_bias` itself.
        #"{"model":"m","messages":[{"role":"user","content":"x"}],"seed":-1}"#,
        #"{"model":"m","messages":[{"role":"user","content":"x"}],"logit_bias":"x"}"#,
    ]

    @Test("merged decode equals the separate calls", arguments: Self.bodies)
    func mergedDecodeMatches(json: String) throws {
        let body = Data(json.utf8)
        #expect(try PromptPreparationProbe.bodyDecodesAgree(body))
        let inbound = try ProviderLoop.decodeInboundChatRequest(body)
        #expect(inbound.request == (try ProviderLoop.decodeOpenAIRequest(body)))
    }

    @Test("rejected bodies fail the same way", arguments: Self.invalidBodies)
    func invalidBodiesStillThrow(json: String) {
        let body = Data(json.utf8)
        #expect(throws: (any Error).self) { try ProviderLoop.decodeOpenAIRequest(body) }
        #expect(throws: (any Error).self) { try ProviderLoop.decodeInboundChatRequest(body) }
    }

    @Test("extensions decode independently")
    func extensionsAreIndependent() throws {
        let inbound = try ProviderLoop.decodeInboundChatRequest(Data(Self.bodies[3].utf8))
        #expect(inbound.extensions.logprobsSpec == nil)
        #expect(inbound.extensions.samplingOverrides == nil)
        let valid = try ProviderLoop.decodeInboundChatRequest(Data(Self.bodies[1].utf8))
        #expect(valid.extensions.logprobsSpec?.topLogprobs == 3)
        #expect(valid.extensions.samplingOverrides == EngineV2SamplingOverrides(
            logitBias: ["11": -100, "12": 2.5], seed: 42))
        let controls = try ProviderLoop.decodeInboundChatRequest(Data(Self.bodies[7].utf8)).extensions.templateControls
        #expect(controls.enableThinking == false)
    }
}
