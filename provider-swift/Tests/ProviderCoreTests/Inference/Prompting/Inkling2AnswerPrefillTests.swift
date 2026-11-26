// Copyright © 2026 Eigen Labs.

import Foundation
import Jinja
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore
@testable import ProviderCoreFoundation

/// Inkling 2 with thinking off, answering at once: asked for by the
/// coordinator's `answer_prefill` hint (or this Mac's override), a thinking-off
/// request with no tools in its prompt has its prompt end with an open answer
/// message and its output read from inside that message; everything else is
/// unchanged.
@Suite("Inkling 2 thinking off answering at once")
struct Inkling2AnswerPrefillTests {
    static let type = Inkling2ModelIdentity.modelType
    static let openAnswer = "<|message_model|><|content_text|>"
    /// Inkling 2's ids for the two markers (`tokenizer_config.json`).
    static let ids = ["<|message_model|>": 200_001, "<|content_text|>": 200_004]
    static let weather = #"[{"type":"function","function":{"name":"get_weather","#
        + #""parameters":{"type":"object","properties":{"city":{"type":"string"}}}}}]"#

    static func request(_ json: String, content: String = #""hi""#) throws
        -> (OpenAIChatCompletionRequest, ChatTemplateControls, ToolChoicePromptPolicy.Prepared)
    {
        let body = Data((#"{"model":"m","messages":[{"role":"user","content":"# + content + "}]" + json + "}").utf8)
        let decoded = try ProviderLoop.decodeOpenAIRequest(body, modelType: type)
        return (decoded, ProviderLoop.extractChatTemplateControls(from: body),
                try ToolChoicePromptPolicy.prepare(decoded, modelType: type))
    }

    /// Whether a request answers at once, asked for by the coordinator's hint
    /// (`hint`) under this Mac's override (`local`).
    static func applies(_ json: String, content: String = #""hi""#, modelType: String? = type,
                        logprobs: Bool = false, hint: Bool = true,
                        local: Inkling2AnswerPrefill.Override = .followsHint) throws -> Bool {
        let (decoded, controls, prepared) = try request(json, content: content)
        return Inkling2AnswerPrefill.applies(decoded, controls: controls.askingAnswerPrefill(hint),
                                             modelType: modelType, prepared: prepared, logprobs: logprobs,
                                             localOverride: local)
    }

    // MARK: - The switch

    @Test func theSwitchReachesTheLaunchAgent() {
        let key = Inkling2AnswerPrefill.environmentKey
        #expect(key == "DARKBLOOM_INKLING_THINKING_OFF_ANSWER_PREFILL")
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "1"])[key] == "1")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }

    /// Unset, or any other value, follows the coordinator's hint; an on word
    /// or an off word overrides it.
    @Test func theSwitchFollowsTheHintUnlessSet() {
        #expect(Inkling2AnswerPrefill.override(environment: [:]) == .followsHint)
        for (raw, expected) in [("1", .on), (" ON ", .on), ("yes", .on), ("true", .on),
                                ("0", .off), ("off", .off), ("No", .off),
                                ("2", .followsHint), ("", .followsHint)] as [(String, Inkling2AnswerPrefill.Override)] {
            #expect(Inkling2AnswerPrefill.override(environment: [Inkling2AnswerPrefill.environmentKey: raw])
                    == expected, "\(raw)")
        }
    }

    /// The scheduler reads the override once per process (`localOverride`); a
    /// task can set it around one request.
    @Test func aTaskCanSetTheOverride() {
        Inkling2AnswerPrefill.$localOverride.withValue(.on) { #expect(Inkling2AnswerPrefill.localOverride == .on) }
        Inkling2AnswerPrefill.$localOverride.withValue(.off) { #expect(Inkling2AnswerPrefill.localOverride == .off) }
    }

    // MARK: - The coordinator's hint

    /// The hint reaches the controls only from the coordinator frame: a body
    /// cannot set it, and the frame's absent or false hint asks nothing.
    @Test func onlyTheFrameSetsTheHint() throws {
        let (_, controls, _) = try Self.request(#","reasoning":{"enabled":false},"answer_prefill":true"#)
        #expect(!controls.answerPrefillHint)
        #expect(controls.servingCoordinatorRequest(planned: false, gemmaPromptContract: nil,
                                                   answerPrefill: true).answerPrefillHint)
        #expect(!controls.servingCoordinatorRequest(planned: false, gemmaPromptContract: nil).answerPrefillHint)
    }

    /// The frame carries `answer_prefill` only when true; a decoder reads only
    /// a boolean true as asking, and a frame without it (an older
    /// coordinator) asks nothing.
    @Test func theFrameHintRoundTrips() throws {
        let asked = CoordinatorMessage.inferenceRequest(.init(requestId: "r", answerPrefill: true))
        let data = try ProviderProtocolCodec.encodeCoordinatorMessage(asked)
        #expect(String(decoding: data, as: UTF8.self).contains(#""answer_prefill":true"#))
        #expect(try ProviderProtocolCodec.decodeCoordinatorMessage(from: data) == asked)
        let plain = try ProviderProtocolCodec.encodeCoordinatorMessage(.inferenceRequest(.init(requestId: "r")))
        #expect(!String(decoding: plain, as: UTF8.self).contains("answer_prefill"))
        for (frame, expected) in [
            (#"{"type":"inference_request","request_id":"r","body":null}"#, false),
            (#"{"type":"inference_request","request_id":"r","body":null,"answer_prefill":true}"#, true),
            (#"{"type":"inference_request","request_id":"r","body":null,"answer_prefill":false}"#, false),
            (#"{"type":"inference_request","request_id":"r","body":null,"answer_prefill":"yes"}"#, false),
        ] {
            guard case .inferenceRequest(let request) = try ProviderProtocolCodec.decodeCoordinatorMessage(from: frame)
            else {
                Issue.record("not an inference request: \(frame)")
                continue
            }
            #expect(request.answerPrefill == expected, "\(frame)")
        }
    }

    /// Unset, the hint decides; the override wins either way.
    @Test func theOverrideDecidesOverTheHint() throws {
        let off = #","reasoning":{"enabled":false}"#
        #expect(try Self.applies(off, hint: true))
        #expect(try !Self.applies(off, hint: false))
        #expect(try Self.applies(off, hint: false, local: .on))
        #expect(try !Self.applies(off, hint: true, local: .off))
    }

    // MARK: - Which requests

    /// Every form of thinking off answers at once when asked (the hint, or the
    /// override on); thinking on, an effort above none and the template
    /// default never do.
    @Test func onlyThinkingOffGetsThePrefill() throws {
        for (json, off) in [
            ("", false), (#","reasoning_effort":"none""#, true), (#","reasoning_effort":"OFF""#, true),
            (#","reasoning_effort":"low""#, false), (#","reasoning":{"enabled":false}"#, true),
            (#","chat_template_kwargs":{"enable_thinking":false}"#, true),
            (#","reasoning":{"enabled":true},"reasoning_effort":"none""#, false),
        ] {
            #expect(try Self.applies(json) == off, "\(json)")
            #expect(try !Self.applies(json, hint: false), "\(json)")
            #expect(try Self.applies(json, hint: false, local: .on) == off, "\(json)")
            #expect(try !Self.applies(json, modelType: "gemma4"), "\(json)")
        }
    }

    /// Declared tools (auto or forced), media and logprobs keep the prompt as before:
    /// the open answer message would leave no place for a call, and the media
    /// and logprob paths read the output from its first frame.
    @Test func toolsMediaAndLogprobsAreUnchanged() throws {
        let off = #","reasoning":{"enabled":false}"#
        #expect(try Self.applies(off))
        #expect(try !Self.applies(off + #","tools":"# + Self.weather))
        #expect(try !Self.applies(off + #","tools":"# + Self.weather + #","tool_choice":"required""#))
        #expect(try !Self.applies(off, logprobs: true))
        let image = #"[{"type":"text","text":"what is this"},"#
            + #"{"type":"image_url","image_url":{"url":"data:image/png;base64,iVBORw0KGgo="}}]"#
        #expect(try !Self.applies(off, content: image))
        // `tool_choice: none` removes the tools from the prompt, so nothing
        // can be called: the request answers at once.
        #expect(try Self.applies(off + #","tools":"# + Self.weather + #","tool_choice":"none""#))
    }

    /// The two markers are ids in the slot's vocabulary, or nothing changes.
    @Test func theOpenAnswerMessageIsTwoVocabularyIds() {
        #expect(Inkling2AnswerPrefill.tokens(tokenToId: { Self.ids[$0] }) == [200_001, 200_004])
        #expect(Inkling2AnswerPrefill.tokens(tokenToId: { $0 == "<|message_model|>" ? 200_001 : nil }) == nil)
        #expect(Inkling2AnswerPrefill.tokens(tokenToId: { _ in -1 }) == nil)
        #expect(Inkling2AnswerPrefill.markers.joined() == Self.openAnswer)
    }

    // MARK: - The prompt and the next turn

    /// The template renders this reply in the next turn's history as an
    /// answer message starting with exactly the two markers, so the prefilled
    /// prompt stays a prefix of the next turn's prompt and prefix reuse holds.
    @Test func thePrefilledPromptIsAPrefixOfTheNextTurn() throws {
        let effort = Value.string("none")
        let first: [[String: Any]] = [["role": "user", "content": "What is the capital of France?"]]
        let prompt = try Inkling2PromptContractTests.render(first, effort: effort) + Self.openAnswer
        let next = try Inkling2PromptContractTests.render(first + [
            ["role": "assistant", "content": "Paris."],
            ["role": "user", "content": "And of Italy?"],
        ], effort: effort)
        #expect(next.hasPrefix(prompt))
        #expect(next.dropFirst(prompt.count).hasPrefix("Paris.<|end_message|><|content_model_end_sampling|>"))
        // Without the prefill the prompt ends between messages, one boundary earlier.
        #expect(prompt.hasSuffix("<|end_message|>" + Self.openAnswer))
    }

    // MARK: - The output

    /// The content and the reasoning one reply reads as.
    static func read(_ reply: String, startsInAnswer: Bool) -> [String] {
        var lexer = Inkling2OutputChannels(callsAreText: true, startsInAnswer: startsInAnswer)
        var content = "", reasoning = ""
        for piece in lexer.parse(reply) + lexer.finish() {
            switch piece {
            case .content(let text): content += text
            case .reasoning(let text): reasoning += text
            case .toolCall: Issue.record("unexpected call")
            }
        }
        return [content, reasoning]
    }

    /// From inside the answer the reply is content up to `<|end_message|>`;
    /// read from the boundary, as without the prefill, the same bytes are
    /// outside every message and dropped.
    @Test func theLexerStartsInsideTheAnswer() {
        let reply = "Paris.<|end_message|><|content_model_end_sampling|>"
        #expect(Self.read(reply, startsInAnswer: true) == ["Paris.", ""])
        #expect(Self.read(reply, startsInAnswer: false) == ["", ""])
        // A thought the model still opens after its answer is reasoning.
        let after = "Paris.<|end_message|><|message_model|><|content_thinking|>ok<|end_message|>"
        #expect(Self.read(after, startsInAnswer: true) == ["Paris.", "ok"])
    }

    /// Starting inside the answer reads a reply exactly as the lexer reads it
    /// after `<|content_text|>`, including an answer that opens with a call
    /// where calls can open answers (`readsCallOpeningAnswer`).
    @Test func startingInsideTheAnswerReadsAsAfterItsMarker() {
        let call = #"get_weather<|content_invoke_tool_json|>{"name":"get_weather","args":{"city":"Paris"}}"#
        for reply in ["Paris.<|end_message|>", call + "<|end_message|>", "Par"] {
            for readsCallOpeningAnswer in [false, true] {
                var started = Inkling2OutputChannels(readsCallOpeningAnswer: readsCallOpeningAnswer,
                                                     startsInAnswer: true)
                var marked = Inkling2OutputChannels(readsCallOpeningAnswer: readsCallOpeningAnswer)
                let fromStart = started.parse(reply) + started.finish()
                let afterMarker = marked.parse("<|content_text|>" + reply) + marked.finish()
                #expect(fromStart == afterMarker, "\(reply), \(readsCallOpeningAnswer)")
                #expect(started.unterminatedChannel == marked.unterminatedChannel, "\(reply)")
            }
        }
    }

    /// The router publishes the answer's first bytes as they arrive, with the
    /// thought withheld as for every thinking-off request.
    @Test func theRouterStreamsTheAnswerFromItsFirstBytes() throws {
        let (_, _, prepared) = try Self.request(#","reasoning":{"enabled":false}"#)
        var router = NativeToolStreamRouter(handler: nil, requiresToolCall: false, nativePrefix: nil,
            tools: nil, withholdReasoning: true, streamedCalls: prepared,
            nativeInklingChannels: true, inklingStartsInAnswer: true)
        var content = ""
        for event in try router.process("Par") {
            if case .parsed(let piece) = event { content += piece.content }
        }
        #expect(content == "Par")
        for event in try router.process("is.<|end_message|><|content_model_end_sampling|>") + router.finishText() {
            if case .parsed(let piece) = event { content += piece.content }
        }
        #expect(content == "Paris.")
    }

    /// Client stop strings apply from the answer's first token: the scope
    /// excludes only thoughts and control-token spellings, and the reply does
    /// not start inside an excluded span.
    @Test func stopStringsApplyFromTheFirstAnswerToken() {
        guard case .outside(let spans, startsInside: let startsInside) = Inkling2AnswerPrefill.stopStringScope.matching
        else {
            Issue.record("expected an excluding scope")
            return
        }
        #expect(!startsInside)
        #expect(spans.contains { $0.opener == "<|content_thinking|>" })
        #expect(!spans.contains { $0.opener == "<|content_text|>" })
    }
}
