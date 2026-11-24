import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Answer text for a header-only message: a request that declares no tools,
/// whose model answers with a message that has a header and no content kind
/// (`<|message_model|>get_weather(city: Paris)<|end_message|>`). That text was
/// dropped as outside every message, so the client got a 200 with empty
/// content. With `callsAreText` it is the answer; requests that declare tools,
/// `none`, and `DARKBLOOM_INKLING_UNDECLARED_CALL_TEXT=0` keep dropping it.
@Suite("Inkling 2 header-only answers without declared tools")
struct Inkling2HeaderOnlyAnswerTests {
    typealias Serve = Inkling2UndeclaredCallTextTests

    /// The 56 tokens Inkling 2 Mini generated for a prompt that describes
    /// `get_weather` in its system message and sends no `tools` (greedy, as
    /// read back from the response's logprobs).
    static let observedTokens = [
        "<|message_model|>", "<|content_thinking|>", "The", " user", " asks", " for", " current", " weather", " in",
        " Paris", ".", " Need", " call", " get", "_", "weather", " with", " city", ".", " Need", " not", " provide",
        " weather", " without", " tool", ".", " Call", " get", "_", "weather", "(", "city", "=", "\"", "Paris", "\"",
        ")", ".", " Then", " answer", " based", " on", " result", ".", "<|end_message|>", "<|message_model|>", "get",
        "_", "weather", "(", "city", ":", " Paris", ")", "<|end_message|>", "<|content_model_end_sampling|>",
    ]
    static var observed: String { observedTokens.joined() }
    static let thoughtText = "The user asks for current weather in Paris. Need call get_weather with city. Need not "
        + "provide weather without tool. Call get_weather(city=\"Paris\"). Then answer based on result."
    static let answer = "get_weather(city: Paris)"

    static func lexed(_ chunks: [String], callsAreText: Bool) -> (Serve.Outcome, Inkling2OutputChannels) {
        var lexer = Inkling2OutputChannels(callsAreText: callsAreText)
        var outcome = Serve.Outcome()
        var pieces: [Inkling2OutputPiece] = []
        for chunk in chunks { pieces += lexer.parse(chunk) }
        pieces += lexer.finish()
        for piece in pieces {
            switch piece {
            case .reasoning(let text): outcome.reasoning += text
            case .content(let text): outcome.content += text
            case .toolCall(let call): outcome.calls.append(call)
            }
        }
        return (outcome, lexer)
    }

    /// The observed output, token by token and at fixed widths: the header's
    /// text is the answer, the thought stays reasoning, nothing else leaks.
    @Test func observedHeaderOnlyMessageIsTheAnswer() {
        let characters = Array(Self.observed)
        var splits = [Self.observedTokens]
        for width in [1, 3, 4096] {
            splits.append(stride(from: 0, to: characters.count, by: width).map {
                String(characters[$0..<min($0 + width, characters.count)])
            })
        }
        for chunks in splits {
            let (outcome, lexer) = Self.lexed(chunks, callsAreText: true)
            #expect(outcome.content == Self.answer)
            #expect(outcome.reasoning == Self.thoughtText)
            #expect(outcome.calls.isEmpty)
            #expect(!outcome.content.contains("<|") && !outcome.content.contains("|>"))
            #expect(lexer.toolFailures.isEmpty)
            #expect(lexer.droppedBytes == "<|end_message|>".utf8.count)
        }
    }

    /// Without `callsAreText` the same output keeps its empty answer.
    @Test func headerOnlyMessageIsDroppedOtherwise() {
        let (outcome, lexer) = Self.lexed(Self.observedTokens, callsAreText: false)
        #expect(outcome.content.isEmpty)
        #expect(outcome.reasoning == Self.thoughtText)
        #expect(lexer.droppedBytes == Self.answer.utf8.count + "<|end_message|>".utf8.count)
    }

    /// Every way a header-only message can end: `<|end_message|>`, EOS,
    /// another message, the end of generation (with or without a marker
    /// prefix), a `<` that opens no marker, and a header over the name bound.
    @Test func everyEndOfAHeaderOnlyMessage() {
        let m = "<|message_model|>"
        let cases: [(String, String)] = [
            (m + "a(b)<|end_message|>", "a(b)"),
            (m + "a(b)<|content_model_end_sampling|>", "a(b)"),
            (m + "a(b)<|message_user|>ignored", "a(b)"),
            (m + "a(b)" + m + "<|content_text|>c<|end_message|>", "a(b)c"),
            (m + "a(b)", "a(b)"),
            (m + "a(b)<|end_mess", "a(b)"),
            (m + "a<b) c<|end_message|>", "a<b) c"),
            (m + String(repeating: "x", count: 300) + "<|end_message|>", String(repeating: "x", count: 300)),
        ]
        for (output, answer) in cases {
            for width in [1, 4096] {
                let (outcome, lexer) = Self.lexed(Self.chunked(output, width: width), callsAreText: true)
                #expect(outcome.content == answer, "\(output) width \(width)")
                #expect(outcome.calls.isEmpty && lexer.toolFailures.isEmpty)
            }
        }
    }

    static func chunked(_ output: String, width: Int) -> [String] {
        let characters = Array(output)
        return stride(from: 0, to: characters.count, by: width).map {
            String(characters[$0..<min($0 + width, characters.count)])
        }
    }

    /// Once a header-only answer goes on as text (past the name bound, or
    /// after a `<` that opens no marker), the next control marker ends it and
    /// is read as a marker: a later message is its own, a thought stays
    /// reasoning, and no marker or its prefix is ever answer text.
    @Test func answerGoingOnEndsAtTheNextMarker() {
        let m = "<|message_model|>"
        let long = String(repeating: "x", count: 300)
        let cases: [(output: String, content: String, reasoning: String)] = [
            (m + long + m + "<|content_text|>more<|end_message|>", long + "more", ""),
            (m + long + m + "<|content_thinking|>secret<|end_message|>", long, "secret"),
            (m + long + "<|content_text|>more<|end_message|>", long + "more", ""),
            (m + "a<b" + m + "<|content_thinking|>t<|end_message|>" + m + "<|content_text|>c<|end_message|>", "a<bc", "t"),
            (m + "a<b<|content_invoke_tool_json|>{}<|end_message|>", "a<b{}", ""),
            (m + "a<b<|message_user|>ignored", "a<b", ""),
            (m + long + "<|end_mess", long, ""),
        ]
        for (output, content, reasoning) in cases {
            for width in [1, 3, 4096] {
                let (outcome, lexer) = Self.lexed(Self.chunked(output, width: width), callsAreText: true)
                #expect(outcome.content == content, "\(output.prefix(40))… width \(width)")
                #expect(outcome.reasoning == reasoning, "\(output.prefix(40))… width \(width)")
                #expect(!outcome.content.contains("<|") && !outcome.content.contains("|>"))
                #expect(outcome.calls.isEmpty && lexer.toolFailures.isEmpty)
            }
        }
    }

    /// The name bound never splits a UTF-8 character: a character that
    /// straddles byte 256 stays whole in the answer.
    @Test(arguments: ["é", "€", "😀"])
    func characterAcrossTheNameBoundStaysWhole(character: String) {
        for pad in 254...256 {
            let answer = String(repeating: "x", count: pad) + character + "yz"
            for width in [1, 4096] {
                let (outcome, _) = Self.lexed(
                    Self.chunked("<|message_model|>" + answer + "<|end_message|>", width: width), callsAreText: true)
                #expect(outcome.content == answer, "pad \(pad) width \(width)")
                #expect(!outcome.content.contains("\u{FFFD}"))
            }
        }
    }

    /// A header followed by its content marker is a name, never answer text.
    @Test func namedMessagesAreUnchanged() {
        let (outcome, _) = Self.lexed(["<|message_model|>Inkling<|content_text|>Hi.<|end_message|>"], callsAreText: true)
        #expect(outcome.content == "Hi.")
    }

    // MARK: - Through the router, as the scheduler serves it

    @Test("the observed output is the answer, plain or streamed", arguments: [false, true])
    func servedAnswer(clientStreams: Bool) throws {
        for width in [1, 7, 4096] {
            let outcome = try Serve.serve(Self.observed, request: Serve.request(clientStreams: clientStreams), width: width)
            #expect(outcome.refusal == nil, "\(outcome.refusal ?? "")")
            #expect(outcome.content == Self.answer)
            #expect(outcome.reasoning == Self.thoughtText)
            #expect(outcome.calls.isEmpty && outcome.deltas == 0)
        }
    }

    /// Declared tools and `none` keep dropping it: no answer, no refusal, no call.
    @Test func declaredToolsAndNoneAreUnchanged() throws {
        for request in [Serve.request(clientStreams: false, tools: try Serve.declared()),
                        Serve.request(clientStreams: true, tools: try Serve.declared()),
                        Serve.request(clientStreams: false, choice: .mode(.none))] {
            let outcome = try Serve.serve(Self.observed, request: request, width: 4096)
            #expect(outcome.refusal == nil, "\(outcome.refusal ?? "")")
            #expect(outcome.content.isEmpty)
            #expect(outcome.calls.isEmpty)
        }
    }

    /// `DARKBLOOM_INKLING_UNDECLARED_CALL_TEXT=0` restores the empty answer.
    @Test func switchOffRestoresTheEmptyAnswer() throws {
        let prepared = try ToolChoicePromptPolicy.prepare(Serve.request(clientStreams: false), modelType: Serve.type)
        var router = Inkling2ToolStreamRouterTests.router(prepared, streams: false, undeclaredCallsAreText: false)
        var content = ""
        for event in try router.process(Self.observed) + router.finishText() {
            if case .parsed(let piece) = event { content += piece.content }
        }
        #expect(content.isEmpty)
        #expect(try router.finishCompleteCalls(truncated: false).calls.isEmpty)
    }

    // MARK: - Client stops

    /// A stop in the header-only answer ends it there; the same word in the
    /// thought does not, and a stop inside a control token never matches.
    @Test func stopsApplyToTheAnswer() throws {
        let scope = Inkling2PromptContract.undeclaredCallTextStopScope
        let cases: [(stop: String, stopped: Bool, content: String)] = [
            ("Paris", true, "get_weather(city: "),
            ("(city", true, "get_weather"),
            ("end", false, Self.answer),
            ("message", false, Self.answer),
            ("result", false, Self.answer),
        ]
        for (stop, stopped, content) in cases {
            let holdback = StopHoldback(stopStrings: [stop], scope: scope)
            var out = ""
            var matched = false
            for token in Self.observedTokens {
                let scan = holdback.ingest(token)
                out += scan.text
                if scan.stopped { matched = true; break }
            }
            if !matched { out += holdback.flush() }
            #expect(matched == stopped, "\(stop)")
            let outcome = try Serve.serve(out, request: Serve.request(clientStreams: true), width: 4096)
            #expect(outcome.refusal == nil, "\(outcome.refusal ?? "")")
            #expect(outcome.content == content, "\(stop)")
            #expect(!outcome.content.contains("<|"))
        }
    }
}
