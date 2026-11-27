import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Inkling 2 Mini's native output protocol (`Inkling2OutputChannels`), read
/// from the pinned `chat_template.jinja` and `response_template`: messages
/// framed by special tokens, reasoning and answer bodies to `<|end_message|>`,
/// one JSON call per `<|content_invoke_tool_json|>` frame.
@Suite("Inkling 2 output channels")
struct Inkling2OutputChannelsTests {
    static let thought = "<|message_model|><|content_thinking|>"
    static let answer = "<|message_model|><|content_text|>"
    static let end = "<|end_message|>"
    static let eos = "<|content_model_end_sampling|>"

    static func call(_ name: String, _ body: String) -> String {
        "<|message_model|>\(name)<|content_invoke_tool_json|>\(body)<|end_message|>"
    }

    /// What one output reads as: channels joined, calls in order.
    struct Reading: Equatable {
        var reasoning = ""
        var content = ""
        var calls: [ToolCall] = []

        init(_ pieces: [Inkling2OutputPiece]) {
            for piece in pieces {
                switch piece {
                case .reasoning(let text): reasoning += text
                case .content(let text): content += text
                case .toolCall(let call): calls.append(call)
                }
            }
        }
    }

    static func read(_ chunks: [String], limits: Inkling2OutputChannels.Limits = .init(),
                     readsCallOpeningAnswer: Bool = false)
        -> (Reading, Inkling2OutputChannels)
    {
        var lexer = Inkling2OutputChannels(limits: limits, readsCallOpeningAnswer: readsCallOpeningAnswer)
        var pieces: [Inkling2OutputPiece] = []
        for chunk in chunks { pieces += lexer.parse(chunk) }
        pieces += lexer.finish()
        return (Reading(pieces), lexer)
    }

    static func read(_ text: String, limits: Inkling2OutputChannels.Limits = .init())
        -> (Reading, Inkling2OutputChannels)
    {
        read([text], limits: limits)
    }

    // MARK: - Well-formed output

    @Test func thoughtThenAnswer() {
        let (reading, lexer) = Self.read(Self.thought + "Let me think.\n" + Self.end
            + Self.answer + "Paris is the capital." + Self.end + Self.eos)
        #expect(reading.reasoning == "Let me think.\n")
        #expect(reading.content == "Paris is the capital.")
        #expect(reading.calls.isEmpty)
        #expect(lexer.toolFailures.isEmpty)
        #expect(lexer.droppedBytes == 0)
        #expect(lexer.unterminatedChannel == nil)
        #expect(lexer.hasReasoning)
    }

    /// The response template's header is optional, and holds an assistant
    /// name on ordinary messages; consecutive messages of one channel join.
    @Test func headersAreOptionalAndChannelsJoin() {
        let (reading, _) = Self.read("<|content_thinking|>a" + Self.end
            + "<|message_model|>Inkling<|content_thinking|>b" + Self.end
            + "<|content_text|>c" + Self.end + Self.answer + "d" + Self.end)
        #expect(reading.reasoning == "ab")
        #expect(reading.content == "cd")
    }

    /// `tool_error` and `invoke_tool_text` are the response template's content.
    @Test func otherContentKindsAreContent() {
        let (reading, _) = Self.read("<|message_model|><|content_tool_error|>e" + Self.end
            + "<|message_model|><|content_invoke_tool_text|>t" + Self.end)
        #expect(reading.content == "et")
    }

    /// `callsAreText` (an `auto` request without tools, #200): every call
    /// frame is content, parsed or not, closed or not; none is a call or a
    /// failure. Without it the same frame is a call.
    @Test func callFramesAreContentWhenCallsAreText() {
        let output = Self.thought + "t" + Self.end
            + Self.call("get_weather", #"{"name":"get_weather","args":{"city":"Paris"}}"#)
            + Self.call("f", #"{"name":"f","arguments":[]}"#)
            + #"<|content_invoke_tool_json|>{"open":"#
        let characters = Array(output)
        for width in [1, 5, 4096] {
            var lexer = Inkling2OutputChannels(callsAreText: true)
            var pieces: [Inkling2OutputPiece] = []
            for start in stride(from: 0, to: characters.count, by: width) {
                pieces += lexer.parse(String(characters[start..<min(start + width, characters.count)]))
            }
            pieces += lexer.finish()
            let reading = Reading(pieces)
            #expect(reading.reasoning == "t")
            #expect(reading.content
                == #"{"name":"get_weather","args":{"city":"Paris"}}{"name":"f","arguments":[]}{"open":"#)
            #expect(reading.calls.isEmpty)
            #expect(lexer.toolFailures.isEmpty)
            #expect(lexer.unterminatedChannel == .content)
            #expect(lexer.droppedBytes == 0)
        }
        let (declared, _) = Self.read(Self.call("get_weather", #"{"name":"get_weather","args":{"city":"Paris"}}"#))
        #expect(declared.calls.map(\.function.name) == ["get_weather"])
    }

    /// The frame bodies a call is read from: the template's `args`, and
    /// `arguments` (the OpenAI shape), each alone beside `name`. Every other
    /// shape is refused (`malformedFrameIsNoCall`).
    @Test(arguments: [
        #"{"name":"get_weather","args":{"location":"Paris"}}"#,
        #"{"name":"get_weather","arguments":{"location":"Paris"}}"#,
        #"{"arguments":{"location":"Paris"},"name":"get_weather"}"#,
    ])
    func callBodyShapesThatParse(body: String) throws {
        let (reading, lexer) = Self.read(Self.thought + "Need weather." + Self.end + Self.call("get_weather", body))
        #expect(lexer.toolFailures.isEmpty)
        let call = try #require(reading.calls.first)
        #expect(reading.calls.count == 1)
        #expect(call.function.name == "get_weather")
        #expect(call.function.arguments == ["location": .string("Paris")])
        #expect(reading.content.isEmpty)
    }

    @Test func toolCallArgumentsKeepTheirValues() throws {
        let body = #"{"name":"get_weather","args":{"b":true,"days":[1,2],"f":1.5,"location":"Paris, France","n":null,"opts":{"unit":"celsius"},"z":0}}"#
        let (reading, lexer) = Self.read(Self.thought + "Need weather." + Self.end + Self.call("get_weather", body))
        #expect(lexer.toolFailures.isEmpty)
        let call = try #require(reading.calls.first)
        #expect(reading.calls.count == 1)
        #expect(call.function.name == "get_weather")
        #expect(call.id == nil)
        #expect(call.function.arguments == [
            "b": .bool(true), "days": .array([.int(1), .int(2)]), "f": .double(1.5),
            "location": .string("Paris, France"), "n": .null, "opts": .object(["unit": .string("celsius")]),
            "z": .int(0),
        ])
        #expect(reading.reasoning == "Need weather.")
        #expect(reading.content.isEmpty)
    }

    @Test func parallelCallsKeepTheirOrder() {
        let (reading, _) = Self.read(Self.call("a", #"{"name":"a","args":{}}"#)
            + Self.call("b", #"{"name":"b","args":{"k":"v"}}"#) + Self.eos)
        #expect(reading.calls.map(\.function.name) == ["a", "b"])
        #expect(reading.calls.first?.function.arguments == [:])
    }

    /// A body without a header names itself.
    @Test func callWithoutHeaderUsesTheBodyName() {
        let (reading, lexer) = Self.read(#"<|content_invoke_tool_json|>{"name":"f","args":{"x":1}}"# + Self.end)
        #expect(reading.calls.map(\.function.name) == ["f"])
        #expect(lexer.toolFailures.isEmpty)
    }

    /// With tools declared (`readsCallOpeningAnswer`), the model sometimes
    /// opens a text message where a call's header belongs:
    /// `<|content_text|>NAME<|content_invoke_tool_json|>{...}`. That message is
    /// the call, alone or beside a well-formed one, at any split.
    @Test func callFrameOpeningAnAnswerIsACall() {
        let body = #"{"name":"update_remarks","args":{"custom_fields":{"備考":"Prefers email"}}}"#
        let wrapped = "update_remarks<|content_invoke_tool_json|>" + body + Self.end
        for opener in [Self.answer, "<|content_text|>"] {
            let output = Self.thought + "Call it." + Self.end + opener + wrapped
                + Self.call("set_note", #"{"name":"set_note","args":{"note":"twice"}}"#) + Self.eos
            let characters = Array(output)
            for width in [1, 3, 4096] {
                let chunks = stride(from: 0, to: characters.count, by: width).map {
                    String(characters[$0..<min($0 + width, characters.count)])
                }
                let (reading, lexer) = Self.read(chunks, readsCallOpeningAnswer: true)
                #expect(reading.calls.map(\.function.name) == ["update_remarks", "set_note"])
                #expect(reading.calls.first?.function.arguments
                    == ["custom_fields": .object(["備考": .string("Prefers email")])])
                #expect(reading.content.isEmpty)
                #expect(reading.reasoning == "Call it.")
                #expect(lexer.toolFailures.isEmpty)
            }
            // Without tools declared the same frame stays the answer's text.
            let (plain, _) = Self.read(Self.thought + "Call it." + Self.end + opener + wrapped)
            #expect(plain.calls.isEmpty)
            #expect(plain.content == "update_remarks<|content_invoke_tool_json|>" + body)
        }
    }

    /// The same frame as a parallel call after a native one: a text message
    /// that opens with `NAME<|content_invoke_tool_json|>` after a completed
    /// call is the second call, at any split (vLLM reads `TOOL_START` from
    /// `CONTENT` after a call too).
    @Test func callFrameOpeningAnAnswerAfterANativeCallIsTheNextCall() {
        let native = Self.call("set_note", #"{"name":"set_note","args":{"note":"twice"}}"#)
        let body = #"{"name":"set_thermostat_offset","args":{"offset":-2.5,"zone":"hall"}}"#
        let wrapped = "set_thermostat_offset<|content_invoke_tool_json|>" + body + Self.end
        for opener in [Self.answer, "<|content_text|>"] {
            let output = Self.thought + "Two calls." + Self.end + native + opener + wrapped + Self.eos
            let characters = Array(output)
            for width in [1, 3, 4096] {
                let chunks = stride(from: 0, to: characters.count, by: width).map {
                    String(characters[$0..<min($0 + width, characters.count)])
                }
                let (reading, lexer) = Self.read(chunks, readsCallOpeningAnswer: true)
                #expect(reading.calls.map(\.function.name) == ["set_note", "set_thermostat_offset"], "\(width)")
                #expect(reading.calls.last?.function.arguments
                    == ["offset": .double(-2.5), "zone": .string("hall")])
                #expect(reading.content.isEmpty)
                #expect(reading.reasoning == "Two calls.")
                #expect(lexer.toolFailures.isEmpty)
            }
            // Without tools declared the frame after the call stays the answer's text.
            let (plain, _) = Self.read([Self.thought + "Two calls." + Self.end + native + opener + wrapped])
            #expect(plain.calls.map(\.function.name) == ["set_note"])
            #expect(plain.content == "set_thermostat_offset<|content_invoke_tool_json|>" + body)
        }
    }

    /// The name before the marker is the call's header, held to the body's name.
    @Test func callFrameOpeningAnAnswerKeepsTheHeaderRule() {
        let (reading, lexer) = Self.read(
            [Self.answer + #"g<|content_invoke_tool_json|>{"name":"f","args":{}}"# + Self.end],
            readsCallOpeningAnswer: true)
        #expect(reading.calls.isEmpty)
        #expect(lexer.toolFailures == [.nameMismatch])
    }

    /// Only a name directly followed by the marker opens a call; other answers,
    /// and a marker later in an answer, stay text, and so does every frame when
    /// calls are text.
    @Test func answersThatAreNoCallFrameStayText() {
        let marker = "<|content_invoke_tool_json|>"
        for text in ["Paris", "Paris is " + marker + "{}", "a b" + marker + "{}", "x" + "<|content_text|>",
                     marker + "{}", String(repeating: "n", count: 65) + marker + "{}"] {
            let (reading, _) = Self.read([Self.answer + text + Self.end], readsCallOpeningAnswer: true)
            #expect(reading.content == text)
            #expect(reading.calls.isEmpty)
        }
        let (unterminated, lexer) = Self.read(["Paris"].map { Self.answer + $0 }, readsCallOpeningAnswer: true)
        #expect(unterminated.content == "Paris")
        #expect(lexer.unterminatedChannel == .content)
        var asText = Inkling2OutputChannels(callsAreText: true, readsCallOpeningAnswer: true)
        let frame = #"f<|content_invoke_tool_json|>{"name":"f","args":{}}"#
        let pieces = asText.parse(Self.answer + frame + Self.end) + asText.finish()
        #expect(Reading(pieces).content == frame)
        #expect(Reading(pieces).calls.isEmpty)
    }

    /// Bytes held while they could still name a call leave with the text that
    /// follows them, so an answer's pieces are the ones it has without tools.
    @Test func heldNameLeavesWithTheFollowingText() {
        var lexer = Inkling2OutputChannels(readsCallOpeningAnswer: true)
        #expect(lexer.parse(Self.answer + "Hel") == [])
        #expect(lexer.openChannel == .content)
        #expect(lexer.parse("lo <|end_mes") == [.content("Hello ")])
        #expect(lexer.parse("sage|>") == [])
        let output = "<|message_model|><|content_thinking|>loop loop <|end_message|><|message_model|><|content_text|>"
            + "The answer.<|end_message|>"
        for options in [false, true] {
            var whole = Inkling2OutputChannels(readsCallOpeningAnswer: options)
            #expect(whole.parse(output) + whole.finish() == [.reasoning("loop loop "), .content("The answer.")])
        }
    }

    // MARK: - Opaque payloads

    /// Markers inside a JSON string are argument data; Unicode and escapes
    /// pass as the JSON decoder reads them.
    @Test func markersInsideArgumentStringsAreData() throws {
        let value = #"a <|end_message|> b <|content_text|> \"q\" \\ é 日本"#
        let body = #"{"name":"echo","args":{"text":""# + value + #""}}"#
        let (reading, lexer) = Self.read(Self.call("echo", body))
        #expect(lexer.toolFailures.isEmpty)
        let call = try #require(reading.calls.first)
        #expect(call.function.arguments["text"] == .string(#"a <|end_message|> b <|content_text|> "q" \ é 日本"#))
    }

    /// A call drafted inside a thought stays the thought's text: a body ends
    /// only at `<|end_message|>`, and no closer is invented.
    @Test func callDraftedInAThoughtIsReasoning() {
        let draft = #"<|message_model|>f<|content_invoke_tool_json|>{"name":"f","args":{}}"#
        let (reading, lexer) = Self.read(Self.thought + "I could " + draft + Self.end
            + Self.answer + "No call needed." + Self.end)
        #expect(reading.calls.isEmpty)
        #expect(reading.reasoning == "I could " + draft)
        #expect(reading.content == "No call needed.")
        #expect(lexer.toolFailures.isEmpty)
    }

    /// Answer text may quote any marker except its own closer.
    @Test func markersInsideAnAnswerAreText() {
        let (reading, _) = Self.read(Self.answer + "Use <|content_thinking|> and <|message_model|>." + Self.end)
        #expect(reading.content == "Use <|content_thinking|> and <|message_model|>.")
        #expect(reading.reasoning.isEmpty)
    }

    // MARK: - Streaming

    /// Every split of the output into two chunks, and byte-sized chunks, read
    /// exactly as the whole output does.
    @Test func everySplitReadsLikeTheWhole() {
        let output = Self.thought + "Think é<|x" + Self.end
            + Self.call("f", #"{"name":"f","args":{"s":"<|end_message|>","n":[{"a":1}]}}"#)
            + Self.answer + "Done 日本." + Self.end + Self.eos
        let (whole, wholeLexer) = Self.read(output)
        #expect(whole.reasoning == "Think é<|x")
        #expect(whole.content == "Done 日本.")
        #expect(whole.calls.count == 1)
        let characters = Array(output)
        for split in 1..<characters.count {
            let (reading, lexer) = Self.read([String(characters[..<split]), String(characters[split...])])
            #expect(reading == whole, "split at \(split)")
            #expect(lexer.droppedBytes == wholeLexer.droppedBytes, "split at \(split)")
        }
        let (bytewise, _) = Self.read(characters.map { String($0) })
        #expect(bytewise == whole)
    }

    /// Answer text streams as it arrives; only a possible closer is held.
    @Test func answerStreamsBeforeItsMessageCloses() {
        var lexer = Inkling2OutputChannels()
        #expect(lexer.parse(Self.answer + "Hel") == [.content("Hel")])
        #expect(lexer.parse("lo <|end_mes") == [.content("lo ")])
        #expect(lexer.openChannel == .content)
        #expect(lexer.parse("sage|>") == [])
        #expect(lexer.openChannel == nil)
    }

    // MARK: - Malformed output

    @Test(arguments: [
        (#"{"name":"f","args":"#, Inkling2ToolFrameFailure.invalidJSON),
        (#"not json"#, .invalidJSON),
        (#"["f",{}]"#, .wrongShape),
        (#"{"name":"f"}"#, .wrongShape),
        (#"{"name":"f","args":"{}"}"#, .wrongShape),
        (#"{"name":"f","args":{},"id":"x"}"#, .wrongShape),
        (#"{"name":"","args":{}}"#, .wrongShape),
        (#"{"name":7,"args":{}}"#, .wrongShape),
        (#"{"name":"g","args":{}}"#, .nameMismatch),
        // The `arguments` shape: still exactly one of the two keys, holding an object.
        (#"{"name":"f","args":{},"arguments":{}}"#, .wrongShape),
        (#"{"name":"f","arguments":[]}"#, .wrongShape),
        (#"{"name":"f","arguments":"{}"}"#, .wrongShape),
        (#"{"name":"f","arguments":null}"#, .wrongShape),
        (#"{"name":"f","parameters":{}}"#, .wrongShape),
        (#"{"name":"f","arguments":{},"id":"x"}"#, .wrongShape),
    ])
    func malformedFrameIsNoCall(body: String, failure: Inkling2ToolFrameFailure) {
        let (reading, lexer) = Self.read(Self.call("f", body) + Self.answer + "after" + Self.end)
        #expect(reading.calls.isEmpty)
        #expect(lexer.toolFailures == [failure])
        // The frame is not text, and what follows it still reads.
        #expect(reading.content == "after")
    }

    @Test func nestingIsBoundedBeforeDecoding() {
        let limits = Inkling2OutputChannels.Limits(toolNestingDepth: 4)
        let within = #"{"name":"f","args":{"a":[[1]]}}"#
        let beyond = #"{"name":"f","args":{"a":[[[1]]]}}"#
        #expect(Self.read(Self.call("f", within), limits: limits).0.calls.count == 1)
        let (reading, lexer) = Self.read(Self.call("f", beyond), limits: limits)
        #expect(reading.calls.isEmpty)
        #expect(lexer.toolFailures == [.nestingTooDeep])
        // Brackets inside strings are not nesting.
        let quoted = #"{"name":"f","args":{"a":"[[[[[[{{{{"}}"#
        #expect(Self.read(Self.call("f", quoted), limits: limits).0.calls.count == 1)
    }

    /// A deeply nested body at the default bound neither recurses nor parses.
    @Test func defaultBoundRefusesDeepNesting() {
        let deep = String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000)
        let (reading, lexer) = Self.read(Self.call("f", #"{"name":"f","args":{"a":"# + deep + "}}"))
        #expect(reading.calls.isEmpty)
        #expect(lexer.toolFailures == [.nestingTooDeep])
    }

    @Test func oversizedBodyEndsTheOutput() {
        let limits = Inkling2OutputChannels.Limits(toolBodyBytes: 32)
        let body = #"{"name":"f","args":{"text":""# + String(repeating: "x", count: 64) + #""}}"#
        let (reading, lexer) = Self.read(Self.call("f", body) + Self.answer + "after" + Self.end, limits: limits)
        #expect(reading.calls.isEmpty)
        #expect(reading.content.isEmpty)
        #expect(lexer.toolFailures == [.bodyTooLarge])
        #expect(lexer.bytesAfterEnd > 0)
    }

    @Test func unterminatedCallIsAFailure() {
        let (reading, lexer) = Self.read(Self.thought + "t" + Self.end
            + #"<|message_model|>f<|content_invoke_tool_json|>{"name":"f","args":{"#)
        #expect(reading.calls.isEmpty)
        #expect(lexer.toolFailures == [.unterminated])
        #expect(lexer.unterminatedChannel == .toolCall)
        // The engine's stop arriving as text inside the frame ends it the same way.
        let (_, stopped) = Self.read(#"<|message_model|>f<|content_invoke_tool_json|>{"name":"f""# + Self.eos)
        #expect(stopped.toolFailures == [.unterminated])
        #expect(stopped.endedByMarker)
    }

    /// A thought or an answer cut off is published as far as it went.
    @Test func unterminatedBodiesKeepTheirText() {
        let (thought, cut) = Self.read(Self.thought + "half a thought <|end_mess")
        #expect(thought.reasoning == "half a thought <|end_mess")
        #expect(cut.unterminatedChannel == .reasoning)
        #expect(cut.toolFailures.isEmpty)
        let (answer, answerCut) = Self.read(Self.answer + "half an answer")
        #expect(answer.content == "half an answer")
        #expect(answerCut.unterminatedChannel == .content)
    }

    /// The output ends at EOS and at another role's turn; nothing after it leaves.
    @Test(arguments: ["<|content_model_end_sampling|>", "<|message_user|>", "<|message_system|>", "<|message_tool|>", "<|endoftext|>",
                      "<|begin_of_text|>"])
    func outputEndsAtAnotherTurn(marker: String) {
        let (reading, lexer) = Self.read(Self.answer + "done" + Self.end + marker
            + Self.answer + "hallucinated turn" + Self.end)
        #expect(reading.content == "done")
        #expect(lexer.endedByMarker)
        #expect(lexer.bytesAfterEnd == (Self.answer + "hallucinated turn" + Self.end).utf8.count)
    }

    /// Text outside every message, and messages the model never answers with,
    /// are dropped as the response template drops them, and counted.
    @Test func unframedTextAndForeignKindsAreDropped() {
        let (reading, lexer) = Self.read("stray<|unused_200054|>" + "<|message_model|><|content_xml|>[]" + Self.end
            + "<|content_image|>x" + Self.end + Self.end + Self.answer + "kept" + Self.end + " \n")
        #expect(reading.content == "kept")
        #expect(reading.reasoning.isEmpty)
        #expect(lexer.droppedBytes == ("stray<|unused_200054|>" + "[]" + "x" + Self.end + " \n").utf8.count)
    }

    @Test func overlongHeaderIsNoMessage() {
        let limits = Inkling2OutputChannels.Limits(headerBytes: 8)
        let (reading, lexer) = Self.read("<|message_model|>" + String(repeating: "n", count: 9)
            + "<|content_text|>x" + Self.end, limits: limits)
        // The content marker after it still opens a message.
        #expect(reading.content == "x")
        #expect(lexer.droppedBytes >= 9)
    }

    @Test func headerWithAnUnknownMarkerIsNoMessage() {
        let (reading, lexer) = Self.read("<|message_model|>f<|unused_1|>" + Self.answer + "x" + Self.end)
        #expect(reading.content == "x")
        #expect(lexer.droppedBytes > 0)
    }
}
