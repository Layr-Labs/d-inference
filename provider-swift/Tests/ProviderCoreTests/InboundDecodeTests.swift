import Foundation
import MLXLMServer
import Testing

@testable import ProviderCore

// Regression coverage for #252: the inbound chat-request decoder used to
// reject several *valid* OpenAI shapes with HTTP 400 and surface a
// misleading `tools[0].function` error (from a legacy fallback decoder)
// instead of the real reason. `decodeOpenAIRequest` now strict-decodes on
// the fast path and normalises the known valid-but-rejected shapes on the
// cold path, surfacing the genuine error when it can't repair the body.
@Suite("Inbound chat-request decode (#252)")
struct InboundDecodeTests {

    private func decode(_ json: String) throws -> OpenAIChatCompletionRequest {
        try ProviderLoop.decodeOpenAIRequest(Data(json.utf8))
    }

    // MARK: - Fast path (unchanged behaviour)

    @Test("well-formed request decodes unchanged")
    func wellFormedRequestDecodes() throws {
        let req = try decode(#"""
        {"model":"m","messages":[{"role":"user","content":"hi"}],"temperature":0.7}
        """#)
        #expect(req.model == "m")
        #expect(req.messages.count == 1)
        #expect(req.messages[0].role == .user)
        #expect(req.messages[0].textContent == "hi")
        #expect(req.temperature == 0.7)
        #expect(req.tools == nil)
    }

    @Test("standard function tool decodes on the fast path")
    func standardFunctionToolDecodes() throws {
        let req = try decode(#"""
        {"model":"m","messages":[{"role":"user","content":"x"}],
         "tools":[{"type":"function","function":{"name":"add"}}]}
        """#)
        #expect(req.tools?.count == 1)
        #expect(req.tools?.first?.function.name == "add")
    }

    @Test("OpenRouter reasoning and named tool choice survive inbound decoding")
    func openRouterToolControlsDecode() throws {
        let req = try decode(#"""
        {
          "model":"gemma-4-26b",
          "messages":[{"role":"user","content":"weather in Boston?"}],
          "tools":[{"type":"function","function":{"name":"get_current_weather","strict":true,
            "parameters":{"type":"object","properties":{"location":{"type":"string"}}}}}],
          "tool_choice":{"type":"function","function":{"name":"get_current_weather"}},
          "reasoning":{"enabled":true},
          "stream":true
        }
        """#)

        #expect(req.reasoning?.enabled == true)
        #expect(req.toolChoice == .function(name: "get_current_weather"))
        #expect(req.tools?.first?.function.name == "get_current_weather")
    }

    // MARK: - Hosted / builtin / custom tools (pass-through ignore)

    @Test("hosted web_search tool is dropped, request still decodes")
    func hostedToolIsDropped() throws {
        let req = try decode(#"""
        {"model":"m","messages":[{"role":"user","content":"search"}],
         "tools":[{"type":"web_search"}]}
        """#)
        #expect(req.messages[0].textContent == "search")
        #expect(req.tools?.isEmpty == true)
    }

    @Test("custom tool is dropped, request still decodes")
    func customToolIsDropped() throws {
        let req = try decode(#"""
        {"model":"m","messages":[{"role":"user","content":"x"}],
         "tools":[{"type":"custom","custom":{"name":"my_tool"}}]}
        """#)
        #expect(req.tools?.isEmpty == true)
    }

    @Test("mixed tools keep function shapes and drop hosted/builtin ones")
    func mixedToolsKeepFunctionDropHosted() throws {
        let req = try decode(#"""
        {"model":"m","messages":[{"role":"user","content":"x"}],
         "tools":[
           {"type":"function","function":{"name":"add","parameters":{"type":"object"}}},
           {"type":"web_search"},
           {"type":"file_search"},
           {"type":"code_interpreter"}
         ]}
        """#)
        #expect(req.tools?.count == 1)
        #expect(req.tools?.first?.function.name == "add")
    }

    // MARK: - Messages that omit `content`

    @Test("assistant message with tool_calls and no content decodes")
    func contentlessAssistantToolCallsDecodes() throws {
        let req = try decode(#"""
        {"model":"m","messages":[
           {"role":"assistant","tool_calls":[
             {"id":"call_1","type":"function",
              "function":{"name":"get_weather","arguments":"{\"city\":\"SF\"}"}}
           ]}
        ]}
        """#)
        #expect(req.messages.count == 1)
        #expect(req.messages[0].role == .assistant)
        #expect(req.messages[0].textContent == "")
        #expect(req.messages[0].toolCalls?.count == 1)
        #expect(req.messages[0].toolCalls?.first?.function.name == "get_weather")
        #expect(req.messages[0].toolCalls?.first?.function.arguments == #"{"city":"SF"}"#)
    }

    @Test("explicit content:null survives the cold path")
    func explicitNullContentSurvives() throws {
        // `developer` forces the cold path; the explicit null must be left
        // intact (not clobbered) and decode to empty content.
        let req = try decode(#"""
        {"model":"m","messages":[{"role":"developer","content":null}]}
        """#)
        #expect(req.messages[0].role == .system)
        #expect(req.messages[0].textContent == "")
    }

    // MARK: - Scalar stop (regression from retiring the legacy lift)

    @Test("scalar stop string is wrapped into a one-element array")
    func scalarStopStringIsWrapped() throws {
        let req = try decode(#"""
        {"model":"m","messages":[{"role":"user","content":"hi"}],"stop":"</s>"}
        """#)
        #expect(req.stop == ["</s>"])
    }

    @Test("array stop decodes unchanged on the fast path")
    func arrayStopDecodes() throws {
        let req = try decode(#"""
        {"model":"m","messages":[{"role":"user","content":"hi"}],"stop":["</s>","<|eot|>"]}
        """#)
        #expect(req.stop == ["</s>", "<|eot|>"])
    }

    @Test("scalar stop composes with other cold-path repairs")
    func scalarStopComposesWithOtherRepairs() throws {
        // developer role forces the cold path; the scalar stop must also be
        // repaired in the same pass.
        let req = try decode(#"""
        {"model":"m","messages":[{"role":"developer","content":"x"}],"stop":"\n\n"}
        """#)
        #expect(req.messages[0].role == .system)
        #expect(req.stop == ["\n\n"])
    }

    // MARK: - Roles

    @Test("developer role is aliased to system")
    func developerRoleAliasedToSystem() throws {
        let req = try decode(#"""
        {"model":"m","messages":[{"role":"developer","content":"be concise"}]}
        """#)
        #expect(req.messages[0].role == .system)
        #expect(req.messages[0].textContent == "be concise")
    }

    @Test("legacy function role is aliased to tool")
    func functionRoleAliasedToTool() throws {
        let req = try decode(#"""
        {"model":"m","messages":[
           {"role":"user","content":"hi"},
           {"role":"function","name":"get_weather","content":"sunny"}
        ]}
        """#)
        #expect(req.messages[1].role == .tool)
        #expect(req.messages[1].textContent == "sunny")
    }

    @Test("legacy assistant function_call is translated to tool_calls")
    func legacyFunctionCallTranslatedToToolCalls() throws {
        let req = try decode(#"""
        {"model":"m","messages":[
           {"role":"user","content":"weather?"},
           {"role":"assistant","function_call":{"name":"get_weather","arguments":"{\"city\":\"SF\"}"}},
           {"role":"function","name":"get_weather","content":"sunny"}
        ]}
        """#)

        #expect(req.messages[1].role == .assistant)
        #expect(req.messages[1].textContent == "")
        #expect(req.messages[1].toolCalls?.count == 1)
        #expect(req.messages[1].toolCalls?.first?.id == "call_legacy_1")
        #expect(req.messages[1].toolCalls?.first?.function.name == "get_weather")
        #expect(req.messages[1].toolCalls?.first?.function.arguments == #"{"city":"SF"}"#)
        #expect(req.messages[2].role == .tool)
    }

    @Test("malformed legacy function_call throws invalidToolPayload")
    func malformedLegacyFunctionCallThrowsInvalidToolPayload() throws {
        #expect(throws: MultiModelBatchSchedulerEngineError.invalidToolPayload(
            "assistant function_call is missing a function name")) {
            _ = try decode(#"""
            {"model":"m","messages":[
               {"role":"assistant","function_call":{"arguments":"{}"}}
            ]}
            """#)
        }
    }

    @Test("unrecognised role throws a clear invalidRole (not a masked decode error)")
    func unknownRoleThrowsInvalidRole() throws {
        #expect(throws: MultiModelBatchSchedulerEngineError.invalidRole("robot")) {
            _ = try decode(#"""
            {"model":"m","messages":[{"role":"robot","content":"beep"}]}
            """#)
        }
    }

    // MARK: - Error surfacing (no masking)

    @Test("genuine error is surfaced, not the tools[0].function red herring")
    func realErrorIsSurfacedNotToolRedHerring() throws {
        // A hosted tool (the historical source of the `tools[0].function`
        // red herring) plus a genuinely broken body (missing `messages`).
        // The surfaced error must name the real problem, not the tool.
        do {
            _ = try decode(#"""
            {"model":"m","tools":[{"type":"web_search"}]}
            """#)
            Issue.record("expected decode to throw for the missing messages key")
        } catch {
            let description = String(describing: error)
            #expect(description.contains("messages"))
            #expect(!description.lowercased().contains("function"))
        }
    }

    @Test("non-object body surfaces the primary strict-decoder error")
    func nonObjectBodySurfacesPrimaryError() throws {
        #expect(throws: (any Error).self) {
            _ = try decode("[]")
        }
    }

    // MARK: - reasoning_effort extraction

    private func effort(_ json: String) -> String? {
        ProviderLoop.extractReasoningEffort(from: Data(json.utf8))
    }

    @Test("reasoning_effort is extracted verbatim")
    func reasoningEffortExtracted() {
        #expect(effort(#"{"model":"m","messages":[],"reasoning_effort":"high"}"#) == "high")
        #expect(effort(#"{"model":"m","messages":[],"reasoning_effort":"low"}"#) == "low")
    }

    @Test("reasoning_effort absent or blank yields nil")
    func reasoningEffortAbsentOrBlank() {
        #expect(effort(#"{"model":"m","messages":[]}"#) == nil)
        #expect(effort(#"{"model":"m","messages":[],"reasoning_effort":""}"#) == nil)
        #expect(effort(#"{"model":"m","messages":[],"reasoning_effort":"  "}"#) == nil)
    }

    @Test("reasoning_effort is trimmed")
    func reasoningEffortTrimmed() {
        #expect(effort(#"{"model":"m","messages":[],"reasoning_effort":"  medium  "}"#) == "medium")
    }

    @Test("non-string reasoning_effort is ignored")
    func reasoningEffortNonString() {
        #expect(effort(#"{"model":"m","messages":[],"reasoning_effort":3}"#) == nil)
    }

    @Test("reasoning.effort is extracted and none is omitted")
    func nestedReasoningEffort() {
        #expect(effort(#"{"model":"m","messages":[],"reasoning":{"effort":"high"}}"#) == "high")
        #expect(effort(#"{"model":"m","messages":[],"reasoning":{"effort":"none"}}"#) == nil)
        #expect(effort(#"{"model":"m","messages":[],"reasoning_effort":"none"}"#) == nil)
    }

    // MARK: - logprobs / top_logprobs extraction

    private func logprobsSpec(_ json: String) -> (topLogprobs: Int?, requested: Bool)? {
        ProviderLoop.extractLogprobsSpec(from: Data(json.utf8))
    }

    @Test("logprobs:true is extracted, with and without top_logprobs")
    func logprobsSpecExtracted() {
        let bare = logprobsSpec(#"{"model":"m","messages":[],"logprobs":true}"#)
        #expect(bare != nil)
        #expect(bare?.topLogprobs == nil)
        let withTop = logprobsSpec(
            #"{"model":"m","messages":[],"logprobs":true,"top_logprobs":5}"#)
        #expect(withTop?.topLogprobs == 5)
    }

    @Test("logprobs absent/false/non-bool yields nil (top_logprobs alone is not a request)")
    func logprobsSpecAbsent() {
        #expect(logprobsSpec(#"{"model":"m","messages":[]}"#) == nil)
        #expect(logprobsSpec(#"{"model":"m","messages":[],"logprobs":false}"#) == nil)
        #expect(logprobsSpec(#"{"model":"m","messages":[],"logprobs":"yes"}"#) == nil)
        // Per the OpenAI contract, top_logprobs is only meaningful when
        // logprobs is true.
        #expect(logprobsSpec(#"{"model":"m","messages":[],"top_logprobs":5}"#) == nil)
    }

    // MARK: - logit_bias / seed extraction (v2 sampling overrides)

    private func sampling(_ json: String) -> EngineV2SamplingOverrides? {
        ProviderLoop.extractSamplingOverrides(from: Data(json.utf8))
    }

    @Test("logit_bias and seed are extracted from the sealed body")
    func samplingOverridesExtracted() {
        let both = sampling(
            #"{"model":"m","messages":[],"logit_bias":{"50256":-100,"42":1.5},"seed":7}"#)
        #expect(both?.logitBias == ["50256": -100, "42": 1.5])
        #expect(both?.seed == 7)
        let biasOnly = sampling(#"{"model":"m","messages":[],"logit_bias":{"1":2}}"#)
        #expect(biasOnly?.logitBias == ["1": 2])
        #expect(biasOnly?.seed == nil)
        let seedOnly = sampling(#"{"model":"m","messages":[],"seed":42}"#)
        #expect(seedOnly?.logitBias == nil)
        #expect(seedOnly?.seed == 42)
    }

    @Test("absent/empty logit_bias and absent seed yield nil (no allocation downstream)")
    func samplingOverridesAbsent() {
        #expect(sampling(#"{"model":"m","messages":[]}"#) == nil)
        #expect(sampling(#"{"model":"m","messages":[],"logit_bias":{}}"#) == nil)
    }

    @Test("a malformed value for one field never discards the other")
    func samplingOverridesFieldIndependence() {
        // Negative seed can't decode as UInt64 — logit_bias must survive.
        let badSeed = sampling(
            #"{"model":"m","messages":[],"logit_bias":{"9":-5},"seed":-1}"#)
        #expect(badSeed?.logitBias == ["9": -5])
        #expect(badSeed?.seed == nil)
        // Non-object logit_bias — seed must survive.
        let badBias = sampling(
            #"{"model":"m","messages":[],"logit_bias":"junk","seed":3}"#)
        #expect(badBias?.logitBias == nil)
        #expect(badBias?.seed == 3)
    }
}
