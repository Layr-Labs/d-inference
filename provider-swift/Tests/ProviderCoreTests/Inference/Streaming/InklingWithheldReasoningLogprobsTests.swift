// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore
@testable import ProviderCoreFoundation

/// Inkling 2 with `logprobs` on, its reasoning returned or withheld: the
/// thought and every frame marker never return as logprob entries
/// (`InklingWithheldReasoningLogprobsFilter`); answer and call tokens keep
/// theirs. The scheduler applies the filter before the SDK's encoders, so the
/// streamed and non-streamed responses agree.
@Suite("Inkling withheld-reasoning logprobs")
struct InklingWithheldReasoningLogprobsTests {
    static let thought = [
        "<|message_model|>", "<|content_thinking|>", "The", " user", " wants", " a", " greeting", ".",
        "<|end_message|>",
    ]
    static let answer = [
        "<|message_model|>", "<|content_text|>", "Hello", " there", ".", "<|end_message|>",
        "<|content_model_end_sampling|>",
    ]
    static let answerTokens = ["Hello", " there", "."]

    static func entries(_ tokens: [String]) -> [SSETokenLogprob] {
        tokens.map {
            SSETokenLogprob(
                token: $0, logprob: -1, bytes: Array($0.utf8).map(Int.init),
                topLogprobs: [.init(token: $0, logprob: -1, bytes: Array($0.utf8).map(Int.init))])
        }
    }

    /// The scheduler's filter for an Inkling request that withholds reasoning.
    static func inklingFilter() throws -> WithheldReasoningLogprobs {
        try #require(
            WithheldReasoningLogprobs.forRequest(
                withholdsReasoning: true, logprobs: true, inklingChannels: true, startsInThought: false))
    }

    /// Feeds `tokens` in groups of `width`, as multi-token engine deltas do.
    static func visible(_ tokens: [String], width: Int) throws -> [String] {
        var filter = try inklingFilter()
        var out: [String] = []
        for start in stride(from: 0, to: tokens.count, by: width) {
            let group = Array(tokens[start ..< min(start + width, tokens.count)])
            out += filter.visible(entries(group)).map(\.token)
        }
        return out
    }

    // MARK: - The filter

    /// Test 1: a withheld thought, then the answer: only the answer's tokens.
    @Test(arguments: [1, 2, 5, 64])
    func aWithheldThoughtNeverReturnsAsEntries(width: Int) throws {
        #expect(try Self.visible(Self.thought + Self.answer, width: width) == Self.answerTokens)
    }

    /// Thoughts may repeat between answer messages; each is withheld.
    @Test(arguments: [1, 3])
    func repeatedThoughtsAreEachWithheld(width: Int) throws {
        let second = [
            "<|message_model|>", "<|content_thinking|>", "Again", "<|end_message|>",
            "<|message_model|>", "<|content_text|>", "Bye", ".", "<|end_message|>",
        ]
        let answerWithoutEnd = Array(Self.answer.dropLast())
        #expect(
            try Self.visible(Self.thought + answerWithoutEnd + second, width: width)
                == Self.answerTokens + ["Bye", "."])
    }

    /// Test 2: a row that only thinks (ended or cut off) returns no entries.
    @Test func aThoughtOnlyRowReturnsNoEntries() throws {
        #expect(try Self.visible(Self.thought + ["<|content_model_end_sampling|>"], width: 1).isEmpty)
        #expect(try Self.visible(Array(Self.thought.dropLast()), width: 4).isEmpty)
    }

    /// A marker inside a thought is the thought's text, as the router reads
    /// it: it does not end the thought early.
    @Test func aMarkerInsideAThoughtDoesNotEndIt() throws {
        let thought = [
            "<|message_model|>", "<|content_thinking|>", "Draft", ":", "<|content_text|>", "secret",
            "<|content_invoke_tool_json|>", "{}", "<|end_message|>",
        ]
        #expect(try Self.visible(thought + Self.answer, width: 1) == Self.answerTokens)
    }

    /// Markers spelled out from ordinary tokens are read like the special tokens.
    @Test func markersSpelledFromOrdinaryTokensAreRead() throws {
        let thought = ["<|message_", "model|>", "<|content_", "thinking|>", "secret", "<|end_", "message|>"]
        #expect(try Self.visible(thought + Self.answer, width: 2) == Self.answerTokens)
    }

    /// A call message after the thought keeps its body's entries; its frame
    /// markers and the header name get none. A direct answer keeps every token.
    @Test func callsAndDirectAnswersKeepTheirTokens() throws {
        let call = [
            "<|message_model|>", "get_weather", "<|content_invoke_tool_json|>", #"{"name""#,
            #":"get_weather","#, #""args":{}}"#, "<|end_message|>",
        ]
        #expect(
            try Self.visible(Self.thought + call, width: 1)
                == [#"{"name""#, #":"get_weather","#, #""args":{}}"#])
        #expect(try Self.visible(Self.answer, width: 1) == Self.answerTokens)
    }

    // MARK: - Which filter a request gets

    /// Control: every `<think>` family keeps `WithheldReasoningLogprobsFilter`
    /// unchanged; nothing is filtered unless reasoning is withheld and
    /// logprobs were asked for.
    @Test func thinkFamiliesKeepTheirFilter() throws {
        var think = try #require(
            WithheldReasoningLogprobs.forRequest(
                withholdsReasoning: true, logprobs: true, inklingChannels: false, startsInThought: false))
        var reference = WithheldReasoningLogprobsFilter()
        let tokens = ["<think>", "a", "</think>", "B", "<", "C"]
        #expect(think.visible(Self.entries(tokens)) == reference.visible(Self.entries(tokens)))
        var startsInside = try #require(
            WithheldReasoningLogprobs.forRequest(
                withholdsReasoning: true, logprobs: true, inklingChannels: false, startsInThought: true))
        #expect(startsInside.visible(Self.entries(["a", "</think>", "B"])).map(\.token) == ["B"])
        guard case .inkling(_) = try Self.inklingFilter() else {
            Issue.record("an Inkling request must get the Inkling filter")
            return
        }
        for (withholds, logprobs) in [(true, false), (false, false)] {
            #expect(
                WithheldReasoningLogprobs.forRequest(
                    withholdsReasoning: withholds, logprobs: logprobs, inklingChannels: true,
                    startsInThought: false) == nil)
        }
        #expect(
            WithheldReasoningLogprobs.forRequest(
                withholdsReasoning: false, logprobs: true, inklingChannels: false, startsInThought: false) == nil)
    }

    /// An Inkling request that asks for logprobs gets its filter whether it
    /// returns or withholds the thought.
    @Test(arguments: [false, true])
    func anInklingRequestWithLogprobsAlwaysGetsItsFilter(withholds: Bool) throws {
        let filter = WithheldReasoningLogprobs.forRequest(
            withholdsReasoning: withholds, logprobs: true, inklingChannels: true, startsInThought: false)
        guard case .inkling(_)? = filter else {
            Issue.record("withholds \(withholds): an Inkling request with logprobs must get the Inkling filter")
            return
        }
    }

    // MARK: - Through the SDK's encoders

    /// The scheduler's event order for one request: each token's filtered
    /// entries, then the router's events for its text.
    /// As the scheduler builds it: `forRequest` decides the filter, and no
    /// filter relays every entry.
    static func schedulerEvents(_ tokens: [String], withholds: Bool = true) throws -> [MLXServerGenerationEvent] {
        var router = NativeToolStreamRouter(
            handler: nil, requiresToolCall: false, nativePrefix: nil, tools: nil, withholdReasoning: withholds,
            streamedCalls: nil, nativeInklingChannels: true, inklingStreamsCalls: false,
            withheldReasoningHeartbeat: false)
        var filter = WithheldReasoningLogprobs.forRequest(
            withholdsReasoning: withholds, logprobs: true, inklingChannels: true, startsInThought: false)
        var events: [MLXServerGenerationEvent] = []
        for token in tokens {
            let requested = entries([token])
            let visible = filter?.visible(requested) ?? requested
            if !visible.isEmpty { events.append(.logprobs(visible)) }
            events += try router.process(token)
        }
        return events + (try router.finishText())
    }

    private struct Fixture: MLXServerEngine {
        let events: [MLXServerGenerationEvent]
        func availableModels() async throws -> [MLXServerModel] { [.init(id: "fixture")] }
        func streamChatCompletion(request: OpenAIChatCompletionRequest) async throws
            -> AsyncThrowingStream<MLXServerGenerationEvent, Error>
        {
            let events = events
            return AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
        func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse { .init(tokens: [1]) }
        func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse { .init(text: "ok") }
        func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse { .init(tokens: [1]) }
    }

    static func request(stream: Bool) -> OpenAIChatCompletionRequest {
        OpenAIChatCompletionRequest(
            model: "fixture", messages: [.init(role: .user, content: .text("Hi"))], stream: stream)
    }

    /// Non-streamed: the response's `logprobs.content` and its text.
    static func collected(_ tokens: [String]) async throws -> (entries: [String], text: String) {
        let service = MLXOpenAIService(engine: Fixture(events: try schedulerEvents(tokens)))
        let response = try await service.createChatCompletion(request: request(stream: false))
        let choice = try #require(response.choices.first)
        let text: String
        switch choice.message.content {
        case .text(let value): text = value
        default: text = ""
        }
        return ((choice.logprobs?.content ?? []).map(\.token), text)
    }

    /// Streamed: every frame's `logprobs.content` entries, in order.
    static func streamed(_ tokens: [String]) async throws -> [String] {
        let service = MLXOpenAIService(engine: Fixture(events: try schedulerEvents(tokens)))
        var out: [String] = []
        for try await frame in try await service.streamChatCompletionFrames(request: request(stream: true)) {
            for line in frame.split(separator: "\n") where line.hasPrefix("data: ") && line != "data: [DONE]" {
                guard
                    let object = try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8))
                        as? [String: Any],
                    let choice = (object["choices"] as? [[String: Any]])?.first,
                    let logprobs = choice["logprobs"] as? [String: Any],
                    let content = logprobs["content"] as? [[String: Any]]
                else { continue }
                out += content.compactMap { $0["token"] as? String }
            }
        }
        return out
    }

    /// Test 1 through both encoders: streamed and non-streamed responses carry
    /// exactly the answer's entries, and the answer text is unchanged.
    @Test func bothEncodersReturnOnlyTheAnswersEntries() async throws {
        let tokens = Self.thought + Self.answer
        let (entries, text) = try await Self.collected(tokens)
        #expect(entries == Self.answerTokens)
        #expect(text == "Hello there.")
        #expect(try await Self.streamed(tokens) == Self.answerTokens)
    }

    /// Test 2 through both encoders: a thought-only row (the non-streamed
    /// response used to return the whole thought) returns no entries.
    @Test func aThoughtOnlyRowReturnsNoEntriesFromEitherEncoder() async throws {
        let (entries, text) = try await Self.collected(Self.thought)
        #expect(entries.isEmpty)
        #expect(text.isEmpty)
        #expect(try await Self.streamed(Self.thought).isEmpty)
    }

    // MARK: - Every reasoning form

    /// The three ways a request sets Inkling's thinking: on and unset return
    /// the thought as reasoning, off withholds it.
    enum Form: String, CaseIterable, Sendable {
        case on, off, unset

        var json: String {
            switch self {
            case .on: return #","reasoning":{"enabled":true}"#
            case .off: return #","reasoning":{"enabled":false}"#
            case .unset: return ""
            }
        }

        /// Whether the scheduler withholds the thought, decided as it decides it.
        func withholds() throws -> Bool {
            let body = Data(
                (#"{"model":"m","messages":[{"role":"user","content":"hi"}],"logprobs":true,"top_logprobs":1"#
                    + json + "}").utf8)
            let type = Inkling2ModelIdentity.modelType
            return Inkling2PromptContract.withholdsReasoning(
                try ProviderLoop.decodeOpenAIRequest(body, modelType: type),
                controls: ProviderLoop.extractChatTemplateControls(from: body), modelType: type)
        }
    }

    /// Streamed: the entries' tokens, their first alternatives and the content deltas, in order.
    static func streamedWithContent(_ tokens: [String], withholds: Bool) async throws
        -> (entries: [String], tops: [String?], content: String)
    {
        let service = MLXOpenAIService(engine: Fixture(events: try schedulerEvents(tokens, withholds: withholds)))
        var entries: [String] = [], tops: [String?] = [], content = ""
        for try await frame in try await service.streamChatCompletionFrames(request: request(stream: true)) {
            for line in frame.split(separator: "\n") where line.hasPrefix("data: ") && line != "data: [DONE]" {
                guard
                    let object = try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8))
                        as? [String: Any],
                    let choice = (object["choices"] as? [[String: Any]])?.first
                else { continue }
                if let delta = choice["delta"] as? [String: Any], let text = delta["content"] as? String {
                    content += text
                }
                guard let logprobs = choice["logprobs"] as? [String: Any],
                    let items = logprobs["content"] as? [[String: Any]]
                else { continue }
                for item in items {
                    entries.append(item["token"] as? String ?? "")
                    tops.append(((item["top_logprobs"] as? [[String: Any]])?.first)?["token"] as? String)
                }
            }
        }
        return (entries, tops, content)
    }

    /// Every form, streamed and not: the entries are exactly the answer's
    /// tokens, they join to `content`, and each keeps its top alternative.
    @Test(arguments: Form.allCases, [false, true])
    func everyFormReturnsOnlyTheAnswersEntries(form: Form, stream: Bool) async throws {
        let withholds = try form.withholds()
        #expect(withholds == (form == .off))
        let tokens = Self.thought + Self.answer
        if stream {
            let (entries, tops, content) = try await Self.streamedWithContent(tokens, withholds: withholds)
            #expect(entries == Self.answerTokens, "\(form)")
            #expect(entries.joined() == content, "\(form)")
            #expect(tops == entries.map { Optional($0) }, "\(form)")
        } else {
            let events = try Self.schedulerEvents(tokens, withholds: withholds)
            let service = MLXOpenAIService(engine: Fixture(events: events))
            let response = try await service.createChatCompletion(request: Self.request(stream: false))
            let choice = try #require(response.choices.first)
            let entries = choice.logprobs?.content ?? []
            guard case .text(let content) = choice.message.content else {
                Issue.record("\(form): no text content")
                return
            }
            #expect(entries.map(\.token) == Self.answerTokens, "\(form)")
            #expect(entries.map(\.token).joined() == content, "\(form)")
            #expect(entries.map { $0.topLogprobs.first?.token } == entries.map { Optional($0.token) }, "\(form)")
        }
    }

    /// Every form, streamed and not: a row that only thinks returns no entries.
    @Test(arguments: Form.allCases, [false, true])
    func everyFormReturnsNoEntriesForAThoughtOnlyRow(form: Form, stream: Bool) async throws {
        let withholds = try form.withholds()
        let tokens = Self.thought + ["<|content_model_end_sampling|>"]
        if stream {
            #expect(try await Self.streamedWithContent(tokens, withholds: withholds).entries.isEmpty, "\(form)")
        } else {
            let events = try Self.schedulerEvents(tokens, withholds: withholds)
            let service = MLXOpenAIService(engine: Fixture(events: events))
            let response = try await service.createChatCompletion(request: Self.request(stream: false))
            #expect((try #require(response.choices.first).logprobs?.content ?? []).isEmpty, "\(form)")
        }
    }
}
