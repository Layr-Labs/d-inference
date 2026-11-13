import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

#if DEBUG
@Suite("GLM tool suffix validation")
struct GLM5ToolFailureTests {
    private let valid = "<tool_call>echo<arg_key>text</arg_key><arg_value>SAFE</arg_value></tool_call>"

    /// A malformed suffix commits no call. A required call fails (422); an
    /// `auto` response returns the suffix as text instead of failing.
    @Test(arguments: [false, true], [1, 7, 4096])
    func malformedSuffixNeverCommitsEarlierCall(forced: Bool, width: Int) async throws {
        let output = valid + "PRIVATE_STRAY"
        let result = try await run(output, forced: forced, width: width)
        expectUnparsed(result, output: output, forced: forced)
    }

    @Test(arguments: [false, true])
    func truncatedSecondCallNeverCommitsEarlierCall(forced: Bool) async throws {
        let output = valid + "<tool_call>echo<arg_key>text"
        let result = try await run(output, forced: forced, width: 1)
        expectUnparsed(result, output: output, forced: forced)
    }

    @Test(arguments: [false, true])
    func validCallSurvives(forced: Bool) async throws {
        let result = try await run(valid, forced: forced, width: 1)
        #expect(result.failure == nil)
        #expect(result.calls.map(\.function.name) == ["echo"])
        #expect(result.visible.isEmpty)
    }

    /// The SDK refuses an oversized suffix while it streams, before EOS: that
    /// still fails the response, `auto` included, before any of it is released.
    @Test(arguments: [false, true])
    func oversizedFrameFailsBeforeFallback(forced: Bool) async throws {
        let output = "<tool_call>echo" + String(repeating: "x", count: (1 << 20) + 1)
        let result = try await run(output, forced: forced, width: 65536)
        #expect(result.calls.isEmpty && result.visible.isEmpty)
        #expect(result.failure == (forced ? .toolChoiceViolation("native GLM tool output is invalid")
            : .generationFailed("native GLM tool output is invalid")))
    }

    /// An oversized suffix never bypasses the EOS checks: a think marker inside
    /// a drafted call is not released, whether the suffix arrives in pieces or
    /// in one delivery.
    @Test(arguments: [65536, 1 << 22])
    func oversizedSuffixIsNeverReleased(width: Int) async throws {
        let draft = "<tool_call>echo<arg_key>text</arg_key><arg_value></think></arg_value></tool_call>"
        let output = "Draft " + draft + "PRIVATE</think>Answer" + String(repeating: "x", count: 1 << 20)
        let result = try await run(output, forced: false, width: width)
        #expect(result.calls.isEmpty && !result.visible.contains("PRIVATE"))
        #expect(result.failure == .generationFailed("native GLM tool output is invalid"))
    }

    /// The model's raw output after the prompt's open `<think>` (the legacy
    /// text path: the tool parser also reads the reasoning), the calls an
    /// `auto` response returns, and its visible text, which the service's
    /// reasoning parser then splits at `</think>`. Shapes from the
    /// conformance replay: a tag mentioned or a call drafted in the thought, a
    /// text answer that mentions the tag, clean calls.
    static let strayCases: [(name: String, output: String, calls: [String], visible: String)] = {
        let call = "<tool_call>echo<arg_key>text</arg_key><arg_value>SAFE</arg_value></tool_call>"
        let other = "<tool_call>echo<arg_key>text</arg_key><arg_value>MORE</arg_value></tool_call>"
        let draft = "<tool_call>echo<arg_key>text</arg_key><arg_value>DRAFT</arg_value></tool_call>"
        return [
            ("call", "Need it.</think>" + call, ["SAFE"], "Need it.</think>"),
            ("call drafted in the thought", "I'll do " + draft + " maybe.</think>" + call, ["SAFE"],
             "I'll do " + draft + " maybe.</think>"),
            ("tag mentioned in the thought", "Wrap it in <tool_call> tags.</think>" + call, ["SAFE"],
             "Wrap it in <tool_call> tags.</think>"),
            ("tag mentioned in the thought, text answer",
             "The tool would need <tool_call> syntax, but I can answer.</think>Zürich is cool.", [],
             "The tool would need <tool_call> syntax, but I can answer.</think>Zürich is cool."),
            ("text answer mentions the tag", "Simple.</think>To call a tool, GLM writes <tool_call> first.", [],
             "Simple.</think>To call a tool, GLM writes <tool_call> first."),
            ("answer quotes a frame, then calls",
             "Simple.</think>The format is <tool_call> … </tool_call>. Calling: " + call, ["SAFE"],
             "Simple.</think>The format is <tool_call> … </tool_call>. Calling: "),
            ("two calls", "Two.</think>" + call + "\n" + other, ["SAFE", "MORE"], "Two.</think>"),
            ("call from an unclosed thought", "Need it." + call, ["SAFE"], "Need it."),
            ("call drafted in the thought, no call", "I'd do " + draft + "</think>", [],
             "I'd do " + draft + "</think>"),
            ("tag mentioned before two calls", "Use <tool_call>.</think>" + call + " " + other + "\n",
             ["SAFE", "MORE"], "Use <tool_call>.</think>"),
        ]
    }()

    @Test(arguments: GLM5ToolFailureTests.strayCases.indices, [1, 4096])
    func strayToolTagsAreTextAndTheFinalCallsParse(index: Int, width: Int) async throws {
        let shape = Self.strayCases[index]
        let result = try await run(shape.output, forced: false, width: width)
        #expect(result.failure == nil, "\(shape.name)")
        #expect(result.calls.count == shape.calls.count, "\(shape.name)")
        #expect(result.calls.compactMap { $0.function.arguments["text"]?.anyValue as? String } == shape.calls,
            "\(shape.name)")
        #expect(result.visible == shape.visible, "\(shape.name)")
    }

    /// A required call keeps failing closed when its suffix does not parse: the
    /// parser's own refusal, or the visible-text check when text precedes it.
    @Test(arguments: [#""required""#, #"{"type":"function","function":{"name":"echo"}}"#])
    func forcedChoiceStillRefusesAStraySuffix(choice: String) async throws {
        let stray = try await run("<tool_call>.</tool_call>" + valid, forced: true, width: 1, choice: choice)
        #expect(stray.calls.isEmpty && stray.visible.isEmpty)
        #expect(stray.failure == .toolChoiceViolation("native GLM tool output is invalid"))
        let mentioned = try await run("Wrap it in <tool_call> tags.</think>" + valid, forced: true, width: 1,
            choice: choice)
        #expect(mentioned.calls.isEmpty && mentioned.visible.isEmpty)
        let failure = try #require(mentioned.failure)
        #expect(ProviderLoop.mapInferenceErrorToStatus(failure) == 422)
    }

    static let storeTool = #"{"type":"function","function":{"name":"store","parameters":{"type":"object","properties":{"doc":{"type":"object"}},"required":["doc"]}}}"#

    /// The delimiters quoted inside a JSON argument are data: the calls start
    /// at the real frame, not at a quoted tag.
    @Test func quotedDelimitersStayArgumentData() async throws {
        let tool = Self.storeTool
        let output = "See <tool_call> here.</think><tool_call>store<arg_key>doc</arg_key>"
            + #"<arg_value>{"x":"</tool_call><tool_call>store"}</arg_value></tool_call>"#
        let result = try await run(output, forced: false, width: 3, tool: tool)
        #expect(result.failure == nil)
        #expect(result.calls.count == 1)
        #expect(result.calls.first?.function.arguments["doc"] == .object(["x": .string("</tool_call><tool_call>store")]))
        #expect(result.visible == "See <tool_call> here.</think>")
    }

    /// An undeclared or malformed final call is not salvaged: the response is
    /// text, as are its earlier calls.
    @Test func malformedFinalCallIsText() async throws {
        let output = "Use <tool_call>.</think>" + valid
            + "<tool_call>nope<arg_key>text</arg_key><arg_value>a</arg_value></tool_call>"
        let result = try await run(output, forced: false, width: 5)
        #expect(result.failure == nil)
        #expect(result.calls.isEmpty)
        #expect(result.visible == output)
    }

    /// Calls are never split out of a suffix that did not parse in an output
    /// the token limit cut off; a suffix that parses keeps its calls, as before.
    @Test func truncatedOutputIsNotSplit() async throws {
        let output = "Wrap it in <tool_call> tags.</think>" + valid
        let result = try await run(output, forced: false, width: 4, finishReason: "length")
        #expect(result.failure == nil)
        #expect(result.calls.isEmpty)
        #expect(result.visible == output)
        let clean = try await run("Need it.</think>" + valid, forced: false, width: 4, finishReason: "length")
        #expect(clean.failure == nil && clean.calls.count == 1 && clean.visible == "Need it.</think>")
    }

    /// A frame that has started its arguments owns everything up to its own
    /// `</tool_call>`: a frame inside an argument, or after one, is data and
    /// never becomes a call, whether the outer frame is cut off or closed.
    @Test(arguments: [nil, "length"], [1, 7, 4096])
    func framesInsideAFrameAreNeverCalls(finishReason: String?, width: Int) async throws {
        let nested = "<tool_call>store<arg_key>doc</arg_key><arg_value>{}</arg_value></tool_call>"
        let cases: [(output: String, tool: String?)] = [
            ("<tool_call>store<arg_key>doc</arg_key><arg_value>{\"x\":\"" + nested, Self.storeTool),
            ("<tool_call>echo<arg_key>text</arg_key><arg_value>draft " + valid, nil),
            ("Use <tool_call>.</think><tool_call>echo<arg_key>text</arg_key><arg_value>a</arg_value>junk" + valid, nil),
        ]
        for shape in cases {
            let result = try await run(shape.output, forced: false, width: width, finishReason: finishReason,
                tool: shape.tool)
            #expect(result.failure == nil && result.calls.isEmpty, "\(shape.output)")
            #expect(result.visible == shape.output, "\(shape.output)")
        }
    }

    /// Arguments that break the SDK's grammar end the lexer's reading of
    /// frames: a frame after them (here quoted in a JSON string the malformed
    /// value opened) stays data and never becomes a call, whether the output
    /// stops or is cut off. So does one after a name followed by anything but
    /// `<arg_key>` or `</tool_call>` that belongs to a frame.
    @Test(arguments: ["stop", "length"], [1, 7, 4096])
    func framesAfterMalformedArgumentsAreNeverCalls(finishReason: String, width: Int) async throws {
        let inner = "<tool_call>store<arg_key>doc</arg_key><arg_value>{}</arg_value></tool_call>"
        let open = "<tool_call>store<arg_key>doc</arg_key><arg_value>"
        let outputs = [
            open + #"{"x": ],"y":""# + "</tool_call>" + inner,
            open + #"{"x": <bad>,"y":""# + "</tool_call>" + inner,
            open + #"{"x": 1 "y":""# + "</tool_call>" + inner,
            "<tool_call>store<arg_value>" + inner,
            "<tool_call>store</arg_value>" + inner,
            "<tool_call>store</arg_key>" + inner,
        ]
        for output in outputs {
            let result = try await run(output, forced: false, width: width, finishReason: finishReason,
                tool: Self.storeTool)
            #expect(result.failure == nil && result.calls.isEmpty, "\(output)")
            #expect(result.visible == output, "\(output)")
        }
    }

    /// Released text would hand a think marker from inside a drafted call to
    /// the service's reasoning parser as a channel boundary: that response keeps
    /// failing, as before.
    @Test func thinkMarkerInsideAReleasedFrameStillFails() async throws {
        let draft = "Draft <tool_call>echo<arg_key>text</arg_key><arg_value></think></arg_value></tool_call>"
        for output in [draft + "PRIVATE</think>Answer", draft + " more.</think>" + valid] {
            let result = try await run(output, forced: false, width: 5)
            #expect(result.calls.isEmpty && result.visible == "Draft ")
            #expect(result.failure == .generationFailed("native GLM tool output is invalid"))
        }
    }

    /// The same holds for a think marker in a key, after a frame whose
    /// arguments break the grammar (which owns the rest of the response), and
    /// in an output cut off at the token limit, whose whole suffix would be
    /// released.
    @Test(arguments: [1, 5, 4096])
    func thinkMarkerAnywhereInAReleasedFrameStillFails(width: Int) async throws {
        let cases: [(output: String, finishReason: String, tool: String?)] = [
            ("Draft <tool_call>echo<arg_key></think></arg_key><arg_value>0</arg_value></tool_call>PRIVATE</think>Answer",
             "stop", nil),
            ("Draft <tool_call>store<arg_key>doc</arg_key><arg_value>{bad}</arg_value></tool_call>PRIVATE</think>Answer",
             "stop", Self.storeTool),
            ("Draft <tool_call>. <tool_call>echo<arg_key>text</arg_key><arg_value></think>PRIVATE</arg_value></tool_call>",
             "length", nil),
            ("Draft <tool_call>echo<bad><arg_key>text</arg_key><arg_value></think></arg_value></tool_call>PRIVATE</think>Answer",
             "stop", nil),
            ("Draft <tool_call>echo<bad><arg_key>text</arg_key><arg_value></think></arg_value></tool_call>PRIVATE</think>Answer",
             "length", nil),
        ]
        for shape in cases {
            let result = try await run(shape.output, forced: false, width: width, finishReason: shape.finishReason,
                tool: shape.tool)
            #expect(result.calls.isEmpty && result.visible == "Draft ", "\(shape.output)")
            #expect(result.failure == .generationFailed("native GLM tool output is invalid"), "\(shape.output)")
        }
    }

    /// `store` with a declared object key `é` (U+00E9) and string-typed
    /// additional properties.
    static let accentTool = #"{"type":"function","function":{"name":"store","parameters":{"type":"object","properties":{"\u00e9":{"type":"object"}},"additionalProperties":{"type":"string"}}}}"#

    /// A frame never borrows a later frame's closing tags: a raw value holding
    /// the SDK's frame tags (which the SDK refuses), a malformed header that
    /// leads into arguments, and a key the SDK refuses because it only
    /// canonically equals a declared one each make the frame own the rest, so
    /// no frame after it is a call, at a stop or the token limit.
    @Test(arguments: ["stop", "length"], [1, 7, 4096])
    func framesNeverBorrowALaterFramesClose(finishReason: String, width: Int) async throws {
        let echo = { (text: String) in "<tool_call>echo<arg_key>text</arg_key><arg_value>\(text)</arg_value></tool_call>" }
        let inner = "<tool_call>store<arg_key>doc</arg_key><arg_value>{}</arg_value></tool_call>"
        let cases: [(output: String, tool: String?)] = [
            ("<tool_call>echo<arg_key>text</arg_key><arg_value>draft " + echo("ONE") + echo("TWO"), nil),
            ("<tool_call>store<bad><arg_key>doc</arg_key><arg_value>{\"x\":\"" + inner, Self.storeTool),
            ("<tool_call>store<arg_key>e\u{301}</arg_key><arg_value>{\"x\":\"</arg_value></tool_call><tool_call>store</tool_call>",
             Self.accentTool),
        ]
        for shape in cases {
            let result = try await run(shape.output, forced: false, width: width, finishReason: finishReason,
                tool: shape.tool)
            #expect(result.failure == nil && result.calls.isEmpty, "\(shape.output)")
            #expect(result.visible == shape.output, "\(shape.output)")
        }
    }

    /// A frame the SDK refuses keeps its boundary only when no reading could
    /// move it: a `"` in it may open a JSON string that runs past its
    /// `</arg_value>` (a raw guess for a schema the SDK refuses), or a raw
    /// string a JSON reading runs past (swallowing the next frame's opening).
    /// Such a frame owns the rest. And a frame's tags in top-level text, here
    /// after a closed frame that follows a malformed header, own the rest too.
    /// No call either way, at a stop or the token limit.
    @Test(arguments: ["stop", "length"], [1, 7, 4096])
    func refusedFramesWithAMovableBoundaryOwnTheRest(finishReason: String, width: Int) async throws {
        let refusedObject = #"{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"x":{"type":"object","anyOf":[{"type":"object"}]}}}}}"#
        let arrayTools = #"[{"type":"function","function":{"name":"put","parameters":{"type":"object","properties":{"m":{"type":"array"}}}}},{"type":"function","function":{"name":"g","parameters":{"type":"object","properties":{}}}},{"type":"function","function":{"name":"h","parameters":{"type":"object","properties":{"z":{"type":"string"}}}}}]"#
        let headerTools = #"[{"type":"function","function":{"name":"store","parameters":{"type":"object","properties":{"doc":{"type":"object"}}}}},{"type":"function","function":{"name":"x"}},{"type":"function","function":{"name":"g","parameters":{"type":"object","properties":{}}}}]"#
        let cases: [(output: String, tool: String)] = [
            (#"<tool_call>f<arg_key>x</arg_key><arg_value>]{"y":"</arg_value></tool_call><tool_call>f</tool_call>"#,
             refusedObject),
            (#"<tool_call>g<arg_key>x</arg_key><arg_value>]{"y":"</arg_value></tool_call><tool_call>f</tool_call>"#,
             refusedObject),
            (#"<tool_call>put<arg_key>m</arg_key><arg_value>"x</arg_value></tool_call><tool_call>put<arg_key>m</arg_key><arg_value>["</arg_value></tool_call><tool_call>g</tool_call><tool_call>h<arg_key>z</arg_key><arg_value>"]</arg_value></tool_call>"#,
             arrayTools),
            (#"<tool_call>store<bad><tool_call>x</tool_call><arg_key>doc</arg_key><arg_value>{"x":"<tool_call>g</tool_call>"#,
             headerTools),
        ]
        for shape in cases {
            let result = try await run(shape.output, forced: false, width: width, finishReason: finishReason,
                tool: shape.tool)
            #expect(result.failure == nil && result.calls.isEmpty, "\(shape.output)")
            #expect(result.visible == shape.output, "\(shape.output)")
        }
    }

    /// Their think markers are then inside a frame: released text holding one
    /// still fails, at a stop or the token limit.
    @Test(arguments: ["stop", "length"], [1, 5, 4096])
    func thinkMarkersAfterAMovableBoundaryStillFail(finishReason: String, width: Int) async throws {
        let refusedObject = #"{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"x":{"type":"object","anyOf":[{"type":"object"}]}}}}}"#
        let headerTools = #"[{"type":"function","function":{"name":"echo","parameters":{"type":"object","properties":{"text":{"type":"string"}}}}},{"type":"function","function":{"name":"x"}}]"#
        let cases: [(output: String, tool: String)] = [
            (#"<tool_call>f<arg_key>x</arg_key><arg_value>]{"y":"</arg_value></tool_call></think>PRIVATE</think>Answer"#,
             refusedObject),
            ("<tool_call>echo<bad><tool_call>x</tool_call><arg_key>text</arg_key><arg_value></think></arg_value></tool_call>PRIVATE</think>Answer",
             headerTools),
        ]
        for shape in cases {
            let result = try await run(shape.output, forced: false, width: width, finishReason: finishReason,
                tool: shape.tool)
            #expect(result.calls.isEmpty && result.visible.isEmpty, "\(shape.output)")
            #expect(result.failure == .generationFailed("native GLM tool output is invalid"), "\(shape.output)")
        }
    }

    /// A frame's tag in top-level text also takes back the malformed header
    /// read as a mention before it: a think marker in that header's region,
    /// either way, still fails.
    @Test(arguments: ["stop", "length"], [1, 5, 4096])
    func orphanTagsTakeBackAnEarlierMention(finishReason: String, width: Int) async throws {
        let headerTools = #"[{"type":"function","function":{"name":"echo","parameters":{"type":"object","properties":{"text":{"type":"string"}}}}},{"type":"function","function":{"name":"x"}}]"#
        let orphan = "<tool_call>x</tool_call><arg_key>text</arg_key><arg_value>v</arg_value></tool_call>"
        for (output, visible) in [
            ("<tool_call>echo<bad></think>PRIVATE" + orphan, ""),
            ("Done.</think><tool_call>echo<bad><think>PRIVATE" + orphan, "Done.</think>"),
        ] {
            let result = try await run(output, forced: false, width: width, finishReason: finishReason,
                tool: headerTools)
            #expect(result.calls.isEmpty && result.visible == visible, "\(output)")
            #expect(result.failure == .generationFailed("native GLM tool output is invalid"), "\(output)")
        }
    }

    /// And a closed frame before it: its value may run on, unescaped, through
    /// the orphan tags (the template writes strings raw), so a think marker
    /// between them, either way, still fails.
    @Test(arguments: ["stop", "length"], [1, 5, 4096])
    func orphanTagsTakeBackAnEarlierFrame(finishReason: String, width: Int) async throws {
        let echo = "<tool_call>echo<arg_key>text</arg_key><arg_value>x</arg_value></tool_call>"
        for (output, visible) in [
            (echo + "</think>PRIVATE</arg_value></tool_call>", ""),
            ("Done.</think>" + echo + "<think>HIDDEN</arg_value></tool_call>", "Done.</think>"),
        ] {
            let result = try await run(output, forced: false, width: width, finishReason: finishReason)
            #expect(result.calls.isEmpty && result.visible == visible, "\(output)")
            #expect(result.failure == .generationFailed("native GLM tool output is invalid"), "\(output)")
        }
    }

    /// A trailing run with a member the SDK refuses is not a batch to take
    /// part of: no member of it runs, as the SDK's own batch rule says (an
    /// undeclared name, a missing required argument).
    @Test(arguments: [1, 7, 4096])
    func aRefusedMemberCancelsTheWholeRun(width: Int) async throws {
        let london = "<tool_call>echo<arg_key>text</arg_key><arg_value>London</arg_value></tool_call>"
        for output in [
            "Checking.</think><tool_call>ech<arg_key>text</arg_key><arg_value>Paris</arg_value></tool_call>\n" + london,
            "Checking.</think><tool_call>echo</tool_call>\n" + london,
        ] {
            let result = try await run(output, forced: false, width: width, finishReason: "stop")
            #expect(result.failure == nil && result.calls.isEmpty, "\(output)")
            #expect(result.visible == output, "\(output)")
        }
    }

    /// Declared keys (byte for byte) and additional properties keep their
    /// types after a mention: the final call parses.
    @Test func declaredAndAdditionalKeysStillParse() async throws {
        for (frame, key, value) in [
            ("<tool_call>store<arg_key>\u{e9}</arg_key><arg_value>{}</arg_value></tool_call>", "\u{e9}",
             JSONValue.object([:])),
            ("<tool_call>store<arg_key>note</arg_key><arg_value>plain {text}</arg_value></tool_call>", "note",
             JSONValue.string("plain {text}")),
        ] {
            let result = try await run("Use <tool_call>.</think>" + frame, forced: false, width: 3, finishReason: "stop",
                tool: Self.accentTool)
            #expect(result.failure == nil && result.visible == "Use <tool_call>.</think>", "\(frame)")
            #expect(result.calls.map { $0.function.arguments } == [[key: value]], "\(frame)")
        }
    }

    /// A think marker inside the final call's own argument is that call's
    /// data: the call parses and nothing of it is released.
    @Test func thinkMarkerInsideTheFinalCallStaysItsArgument() async throws {
        let call = "<tool_call>echo<arg_key>text</arg_key><arg_value>strip </think> tags</arg_value></tool_call>"
        let result = try await run("Use <tool_call>.</think>" + call, forced: false, width: 3, finishReason: "stop")
        #expect(result.failure == nil)
        #expect(result.calls.compactMap { $0.function.arguments["text"]?.anyValue as? String } == ["strip </think> tags"])
        #expect(result.visible == "Use <tool_call>.</think>")
    }

    // MARK: - At a cut that ends as `length` (#2053, `TokenLimitCutPolicy`)
    //
    // The cases above keep #2052's contract, which is this branch's with
    // `DARKBLOOM_LENGTH_FINISH_AT_LIMIT=0` (`run` turns the cut policy off
    // unless asked). With it on, as in production, a cut that ends as
    // `length` drops the frames that end the output instead of publishing
    // them, and drops a suffix it cannot release instead of failing.

    /// Outputs the token limit cut, and their visible text: the frames that
    /// end the output are dropped, from a frame that owns the rest or a header
    /// the limit cut (in its name or a tag, after the start of a declared
    /// name), back over the closed frames before it, whole calls included; a
    /// `<tool_call>` the lexer reads as a mention stays text with what follows,
    /// unless a frame's tag later in top-level text owns the rest from it.
    static let cutCases: [(output: String, visible: String, tool: String?)] = {
        let call = "<tool_call>echo<arg_key>text</arg_key><arg_value>SAFE</arg_value></tool_call>"
        let other = "<tool_call>echo<arg_key>text</arg_key><arg_value>MORE</arg_value></tool_call>"
        let nested = "<tool_call>store<arg_key>doc</arg_key><arg_value>{}</arg_value></tool_call>"
        let headerTools = #"[{"type":"function","function":{"name":"echo","parameters":{"type":"object","properties":{"text":{"type":"string"}}}}},{"type":"function","function":{"name":"x"}}]"#
        let orphan = "<tool_call>x</tool_call><arg_key>text</arg_key><arg_value>v</arg_value></tool_call>"
        let refusedObject = #"{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"x":{"type":"object","anyOf":[{"type":"object"}]}}}}}"#
        let arrayTools = #"[{"type":"function","function":{"name":"put","parameters":{"type":"object","properties":{"m":{"type":"array"}}}}},{"type":"function","function":{"name":"g","parameters":{"type":"object","properties":{}}}},{"type":"function","function":{"name":"h","parameters":{"type":"object","properties":{"z":{"type":"string"}}}}}]"#
        let storeHeaderTools = #"[{"type":"function","function":{"name":"store","parameters":{"type":"object","properties":{"doc":{"type":"object"}}}}},{"type":"function","function":{"name":"x"}},{"type":"function","function":{"name":"g","parameters":{"type":"object","properties":{}}}}]"#
        return [
            // A frame's tag in top-level text owns the rest from the first
            // frame or mention before it (none of these holds a think marker).
            (orphan, "", headerTools),
            ("Use <tool_call>. " + orphan, "Use ", headerTools),
            ("Done.</think>Use <tool_call> here; e.g. <tool_call>f</tool_call> then </arg_key> closes a key. More.",
             "Done.</think>Use ", nil),
            // Frames the SDK refuses whose boundary another reading could move.
            (#"<tool_call>f<arg_key>x</arg_key><arg_value>]{"y":"</arg_value></tool_call><tool_call>f</tool_call>"#,
             "", refusedObject),
            (#"<tool_call>g<arg_key>x</arg_key><arg_value>]{"y":"</arg_value></tool_call><tool_call>f</tool_call>"#,
             "", refusedObject),
            (#"<tool_call>put<arg_key>m</arg_key><arg_value>"x</arg_value></tool_call><tool_call>put<arg_key>m</arg_key><arg_value>["</arg_value></tool_call><tool_call>g</tool_call><tool_call>h<arg_key>z</arg_key><arg_value>"]</arg_value></tool_call>"#,
             "", arrayTools),
            (#"<tool_call>store<bad><tool_call>x</tool_call><arg_key>doc</arg_key><arg_value>{"x":"<tool_call>g</tool_call>"#,
             "", storeHeaderTools),
            // A think marker only in the frames the cut drops: the rest is released.
            ("I'd wrap it in <tool_call> tags.</think>The answer is 42. "
                + "<tool_call>echo<arg_key>text</arg_key><arg_value>strip </think> and",
             "I'd wrap it in <tool_call> tags.</think>The answer is 42. ", nil),
            // A header cut in its name whose name is not declared is a mention.
            ("Calling.</think><tool_call>zz", "Calling.</think><tool_call>zz", nil),
            ("Wrap it in <tool_call> tags.</think>" + call, "Wrap it in <tool_call> tags.</think>", nil),
            ("Use <tool_call>.</think>" + call + " " + other + "\n", "Use <tool_call>.</think>", nil),
            (call + "<tool_call>echo<arg_key>text", "", nil),
            ("Calling.</think>" + call + "\n<tool_call>echo<arg_key>text</arg_key><arg_value>MO", "Calling.</think>", nil),
            ("Calling.</think>" + call + "\n<tool_call>ec", "Calling.</think>", nil),
            ("Calling.</think><tool_call>", "Calling.</think>", nil),
            ("Calling.</think>" + call + "<tool_call>echo<arg_", "Calling.</think>", nil),
            ("<tool_call>store<arg_key>doc</arg_key><arg_value>{\"x\":\"" + nested, "", GLM5ToolFailureTests.storeTool),
            ("<tool_call>echo<arg_key>text</arg_key><arg_value>draft " + call, "", nil),
            ("Use <tool_call>.</think><tool_call>echo<arg_key>text</arg_key><arg_value>a</arg_value>junk" + call,
             "Use <tool_call>.</think>", nil),
            ("The tool would need <tool_call> syntax, but I can answer.</think>Zürich is cool.",
             "The tool would need <tool_call> syntax, but I can answer.</think>Zürich is cool.", nil),
            ("Simple.</think>To call a tool, GLM writes <tool_call> first.",
             "Simple.</think>To call a tool, GLM writes <tool_call> first.", nil),
        ]
    }()

    @Test(arguments: GLM5ToolFailureTests.cutCases.indices, [1, 7, 4096])
    func framesTheLimitCutAreDroppedAndMentionsStay(index: Int, width: Int) async throws {
        let shape = Self.cutCases[index]
        let result = try await run(shape.output, forced: false, width: width, finishReason: "length",
            tool: shape.tool, cutAnswersEndAtLength: true)
        #expect(result.failure == nil && result.calls.isEmpty, "\(shape.output)")
        #expect(result.visible == shape.visible, "\(shape.output)")
    }

    /// A header the end cut matches any declared name, even one whose
    /// declaration the SDK refuses (here an indirect schema): the frame the
    /// limit cut is dropped. An undeclared name is a mention.
    @Test func aCutHeaderMatchesAnyDeclaredName() {
        let required: [String: any Sendable] = ["required": ["q"]]
        let parameters: [String: any Sendable] = ["type": "object", "anyOf": [required] as [any Sendable]]
        let function: [String: any Sendable] = ["name": "lookup", "parameters": parameters]
        let tools: [[String: any Sendable]] = [["type": "function", "function": function]]
        #expect(GLM5ToolSuffix.textAtCut("<tool_call>look", tools: tools) == "")
        #expect(GLM5ToolSuffix.textAtCut("<tool_call>lookup<arg_", tools: tools) == "")
        #expect(GLM5ToolSuffix.textAtCut("<tool_call>zz", tools: tools) == "<tool_call>zz")
    }

    /// A suffix that parses keeps its calls at a cut, as before; one that does
    /// not is not split, and the frames that end it are dropped.
    @Test func aCutSuffixIsNotSplitAndItsFramesAreDropped() async throws {
        let mentioned = try await run("Wrap it in <tool_call> tags.</think>" + valid, forced: false, width: 4,
            finishReason: "length", cutAnswersEndAtLength: true)
        #expect(mentioned.failure == nil && mentioned.calls.isEmpty
            && mentioned.visible == "Wrap it in <tool_call> tags.</think>")
        let clean = try await run("Need it.</think>" + valid, forced: false, width: 4, finishReason: "length",
            cutAnswersEndAtLength: true)
        #expect(clean.failure == nil && clean.calls.count == 1 && clean.visible == "Need it.</think>")
    }

    /// #2052's shapes that own the rest, or whose release would expose a think
    /// marker from inside a frame, at a cut: dropped instead of failing, so
    /// nothing after the kept text is released (`PRIVATE` and `HIDDEN` never);
    /// when a think marker is only in the frames the cut drops, the text before
    /// them is released.
    static let ownedRestCases: [(output: String, visible: String, tool: String?)] = {
        let open = "<tool_call>store<arg_key>doc</arg_key><arg_value>"
        let inner = "<tool_call>store<arg_key>doc</arg_key><arg_value>{}</arg_value></tool_call>"
        let headerTools = #"[{"type":"function","function":{"name":"echo","parameters":{"type":"object","properties":{"text":{"type":"string"}}}}},{"type":"function","function":{"name":"x"}}]"#
        let orphan = "<tool_call>x</tool_call><arg_key>text</arg_key><arg_value>v</arg_value></tool_call>"
        let echo = "<tool_call>echo<arg_key>text</arg_key><arg_value>x</arg_value></tool_call>"
        let refusedObject = #"{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"x":{"type":"object","anyOf":[{"type":"object"}]}}}}}"#
        let store = GLM5ToolFailureTests.storeTool
        return [
            (open + #"{"x": ],"y":""# + "</tool_call>" + inner, "", store),
            (open + #"{"x": <bad>,"y":""# + "</tool_call>" + inner, "", store),
            (open + #"{"x": 1 "y":""# + "</tool_call>" + inner, "", store),
            ("<tool_call>store<arg_value>" + inner, "", store),
            ("<tool_call>store</arg_value>" + inner, "", store),
            ("<tool_call>store</arg_key>" + inner, "", store),
            ("<tool_call>store<arg_key>e\u{301}</arg_key><arg_value>{\"x\":\"</arg_value></tool_call><tool_call>store</tool_call>",
             "", GLM5ToolFailureTests.accentTool),
            (#"<tool_call>f<arg_key>x</arg_key><arg_value>]{"y":"</arg_value></tool_call></think>PRIVATE</think>Answer"#,
             "", refusedObject),
            ("<tool_call>echo<bad><tool_call>x</tool_call><arg_key>text</arg_key><arg_value></think></arg_value></tool_call>PRIVATE</think>Answer",
             "", headerTools),
            ("Draft <tool_call>echo<arg_key>text</arg_key><arg_value></think></arg_value></tool_call>PRIVATE</think>Answer",
             "Draft ", nil),
            ("Draft <tool_call>. <tool_call>echo<arg_key>text</arg_key><arg_value></think>PRIVATE</arg_value></tool_call>",
             "Draft <tool_call>. ", nil),
            ("Draft <tool_call>echo<bad><arg_key>text</arg_key><arg_value></think></arg_value></tool_call>PRIVATE</think>Answer",
             "Draft ", nil),
            ("<tool_call>echo<bad></think>PRIVATE" + orphan, "", headerTools),
            ("Done.</think><tool_call>echo<bad><think>PRIVATE" + orphan, "Done.</think>", headerTools),
            (echo + "</think>PRIVATE</arg_value></tool_call>", "", nil),
            ("Done.</think>" + echo + "<think>HIDDEN</arg_value></tool_call>", "Done.</think>", nil),
        ]
    }()

    @Test(arguments: GLM5ToolFailureTests.ownedRestCases.indices, [1, 5, 4096])
    func whatOwnsTheRestAtACutIsDropped(index: Int, width: Int) async throws {
        let shape = Self.ownedRestCases[index]
        let result = try await run(shape.output, forced: false, width: width, finishReason: "length",
            tool: shape.tool, cutAnswersEndAtLength: true)
        #expect(result.failure == nil && result.calls.isEmpty, "\(shape.output)")
        #expect(result.visible == shape.visible, "\(shape.output)")
        #expect(!result.visible.contains("PRIVATE") && !result.visible.contains("HIDDEN"), "\(shape.output)")
    }

    /// Finding the calls is linear in the suffix: many mentions before them.
    @Test func manyMentionsBeforeTheCalls() async throws {
        let mentions = String(repeating: "<tool_call> ", count: 20_000)
        let result = try await run(mentions + valid, forced: false, width: 65536)
        #expect(result.failure == nil && result.calls.count == 1 && result.visible == mentions)
    }

    /// And many adjacent frames after a mention: the run that ends the
    /// response is collected in one pass.
    @Test func manyFramesAfterAMention() throws {
        let tools: [[String: any Sendable]] = [["type": "function", "function": ["name": "a"] as [String: any Sendable]]]
        let suffix = "<tool_call>." + String(repeating: "<tool_call>a</tool_call>", count: 40_000)
        let split = GLM5ToolSuffix.split(suffix, tools: tools)
        guard case .text(let text, let calls) = split else {
            Issue.record("expected text and calls, got \(split)")
            return
        }
        #expect(text == "<tool_call>." && calls.count == 40_000)
        #expect(calls.allSatisfy { $0.function.name == "a" && $0.function.arguments.isEmpty })
    }

    /// And many additional properties against a large declared schema: each
    /// key's type is one lookup.
    @Test func manyAdditionalKeysAgainstALargeSchema() throws {
        var properties: [String: any Sendable] = [:]
        for index in 0 ..< 5_000 { properties["p\(index)"] = ["type": "string"] as [String: any Sendable] }
        let parameters: [String: any Sendable] = ["type": "object", "properties": properties,
                                                  "additionalProperties": ["type": "string"] as [String: any Sendable]]
        let tools: [[String: any Sendable]] = [["type": "function",
            "function": ["name": "f", "parameters": parameters] as [String: any Sendable]]]
        let arguments = (0 ..< 5_000).map { "<arg_key>x\($0)</arg_key><arg_value>v</arg_value>" }.joined()
        let split = GLM5ToolSuffix.split("<tool_call>.<tool_call>f" + arguments + "</tool_call>", tools: tools)
        guard case .text(let text, let calls) = split else {
            Issue.record("expected text and calls, got \(split)")
            return
        }
        #expect(text == "<tool_call>." && calls.count == 1 && calls.first?.function.arguments.count == 5_000)
    }

    /// And many quote-free frames discarded before the end against many
    /// tools: only frames whose boundary needs it, and the final run, are
    /// checked by the SDK's parser.
    @Test func manyDiscardedFramesAgainstManyTools() throws {
        let tools: [[String: any Sendable]] = (0 ..< 500).map {
            ["type": "function", "function": ["name": "f\($0)"] as [String: any Sendable]]
        }
        let suffix = "<tool_call>." + String(repeating: "<tool_call>f0</tool_call>.", count: 20_000)
        #expect(GLM5ToolSuffix.split(suffix, tools: tools) == .text(suffix, calls: []))
    }

    /// And many discarded frames that the SDK must check (they hold a `"`)
    /// against many tools: each check resolves the frame's one declaration.
    @Test func manyQuotedDiscardedFramesAgainstManyTools() throws {
        var tools: [[String: any Sendable]] = (1 ..< 500).map {
            ["type": "function", "function": ["name": "f\($0)"] as [String: any Sendable]]
        }
        tools.insert(["type": "function", "function": ["name": "f0", "parameters": ["type": "object",
            "properties": ["x": ["type": "string"] as [String: any Sendable]] as [String: any Sendable]]
            as [String: any Sendable]] as [String: any Sendable]], at: 0)
        let frame = #"<tool_call>f0<arg_key>x</arg_key><arg_value>"</arg_value></tool_call>."#
        let suffix = "<tool_call>." + String(repeating: frame, count: 12_000)
        #expect(GLM5ToolSuffix.split(suffix, tools: tools) == .text(suffix, calls: []))
    }

    /// And a long generated name with many arguments: the name is looked up
    /// once per frame, not once per argument.
    @Test func longNameWithManyArguments() throws {
        let tools: [[String: any Sendable]] = [["type": "function", "function": ["name": "echo"] as [String: any Sendable]]]
        let suffix = "<tool_call>" + String(repeating: "a", count: 200_000)
            + String(repeating: "<arg_key>x</arg_key><arg_value>v</arg_value>", count: 5_000) + "</tool_call>"
        #expect(GLM5ToolSuffix.split(suffix, tools: tools) == .text(suffix, calls: []))
    }

    /// `DARKBLOOM_GLM_TOOL_TEXT_FALLBACK=0` restores the whole-suffix failure.
    @Test func rollbackRestoresTheSuffixFailure() throws {
        let request = try MiMoConsumerFixture.request(choice: #""auto""#)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "glm5_next")
        for textFallback in [true, false] {
            let handler = try #require(try ToolStreamPreparation.makeHandler(
                request: request, prepared: prepared, modelType: "glm5_next"))
            var router = NativeToolStreamRouter(handler: handler, requiresToolCall: false, nativePrefix: nil,
                tools: prepared.tools?.map { $0.toolSpec() }, glmUnparsedOutputIsText: textFallback)
            _ = try router.process("Wrap it in <tool_call> tags.</think>" + valid)
            _ = try router.finishText()
            let finished = try router.finishCompleteCalls(truncated: false)
            if textFallback {
                try router.checkNativeToolFailure()
                #expect(finished.calls.count == 1)
                #expect(finished.residual == "<tool_call> tags.</think>")
            } else {
                #expect(finished.calls.isEmpty)
                #expect(throws: MultiModelBatchSchedulerEngineError.generationFailed(
                    "native GLM tool output is invalid")) { try router.checkNativeToolFailure() }
            }
        }
        #expect(GLM5ToolSuffix.environmentKey == "DARKBLOOM_GLM_TOOL_TEXT_FALLBACK")
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(GLM5ToolSuffix.environmentKey))
    }

    /// Only an `auto` request returns an unparsed GLM suffix as text. With any
    /// other prepared choice (here `none`, which the Flint response format
    /// forces while a client-selected parser keeps its handler) no residual
    /// is published, so the suffix still fails.
    @Test func onlyAutoChoiceReturnsTheSuffixAsText() throws {
        let auto = try MiMoConsumerFixture.request(choice: #""auto""#)
        let autoPrepared = try ToolChoicePromptPolicy.prepare(auto, modelType: "glm5_next")
        let nonePrepared = try ToolChoicePromptPolicy.prepare(
            try MiMoConsumerFixture.request(choice: #""none""#), modelType: "glm5_next")
        #expect(nonePrepared.mode == .none)
        for (prepared, fallsBack) in [(autoPrepared, true), (nonePrepared, false)] {
            let handler = try #require(try ToolStreamPreparation.makeHandler(
                request: auto, prepared: autoPrepared, modelType: "glm5_next"))
            var router = NativeToolStreamRouter(handler: handler, requiresToolCall: false, nativePrefix: nil,
                tools: autoPrepared.tools?.map { $0.toolSpec() }, streamedCalls: prepared)
            _ = try router.process("Wrap it in <tool_call> tags.</think>" + valid)
            _ = try router.finishText()
            let finished = try router.finishCompleteCalls(truncated: false)
            if fallsBack {
                try router.checkNativeToolFailure()
                #expect(finished.calls.count == 1)
            } else {
                #expect(finished.calls.isEmpty)
                #expect(throws: MultiModelBatchSchedulerEngineError.generationFailed(
                    "native GLM tool output is invalid")) { try router.checkNativeToolFailure() }
            }
        }
    }

    /// Forced choice is served by structured post-validation: the production
    /// handler is the native GLM parser, which withholds calls until EOS.
    @Test func publicForcedGLMUsesTheWithheldNativeParser() throws {
        for choice in [#""required""#, #"{"type":"function","function":{"name":"echo"}}"#] {
            let request = try MiMoConsumerFixture.request(choice: choice)
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "glm5_next")
            let handler = try #require(try ToolStreamPreparation.makeHandler(
                request: request, prepared: prepared, modelType: "glm5_next"))
            #expect(handler.format == .glm5 && !handler.streamsCalls)
            let context = ChatTemplateFixContext(modelId: request.model, modelType: "glm5_next")
            #expect(try ToolChoiceEnforcementPolicy.forcedStrategy(mode: prepared.mode, modelContext: context)
                == .structuredPostValidation)
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try ToolChoiceEnforcementPolicy.validateParser(.json, strategy: .structuredPostValidation,
                    modelContext: context)
            }
        }
    }

    private struct Outcome {
        var calls: [ToolCall] = []
        var visible = ""
        var failure: MultiModelBatchSchedulerEngineError?
    }

    /// A required call fails closed (422); an `auto` response returns the
    /// unparsed suffix as text, with no call and no failure.
    private func expectUnparsed(_ result: Outcome, output: String, forced: Bool) {
        #expect(result.calls.isEmpty)
        if forced {
            #expect(result.visible.isEmpty)
            #expect(result.failure == .toolChoiceViolation("native GLM tool output is invalid"))
            if let failure = result.failure { #expect(ProviderLoop.mapInferenceErrorToStatus(failure) == 422) }
        } else {
            #expect(result.failure == nil)
            #expect(result.visible == output)
        }
    }

    /// The production event stream on the legacy text path (no native
    /// channel), fed `width` characters at a time. `tool` is one tool or a
    /// JSON array of tools. `cutAnswersEndAtLength`: #2053's cut policy, on in
    /// production; off here unless asked, so #2052's cases keep its contract.
    private func run(_ output: String, forced: Bool, width: Int, finishReason: String? = nil,
                     tool: String? = nil, choice forcedChoice: String = #""required""#,
                     cutAnswersEndAtLength: Bool = false) async throws -> Outcome {
        let choice = forced ? forcedChoice : #""auto""#
        var request = try MiMoConsumerFixture.request(choice: choice)
        if let tool {
            var body = try #require(JSONSerialization.jsonObject(with: MiMoConsumerFixture.body(
                choice: choice)) as? [String: Any])
            let tools = try JSONSerialization.jsonObject(with: Data(tool.utf8))
            body["tools"] = (tools as? [Any]) ?? [tools]
            request = try ProviderLoop.decodeOpenAIRequest(JSONSerialization.data(withJSONObject: body))
        }
        var prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "glm5_next")
        prepared.cutAnswersEndAtLength = cutAnswersEndAtLength
        let handler = try #require(try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: "glm5_next"))
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: { [:] })
        let upstream = AsyncStream<GenerationEvent> { continuation in
            let chars = Array(output)
            for start in stride(from: 0, to: chars.count, by: width) {
                continuation.yield(.chunk(String(chars[start..<min(start + width, chars.count)])))
            }
            if let finishReason {
                continuation.yield(.info(promptTokens: 1, completionTokens: 1, tokensPerSecond: 1,
                    finishReason: finishReason))
            }
            continuation.finish()
        }
        let stream = try scheduler._testMakeEventStream(upstream: upstream, cancelUpstream: {},
            prepared: prepared, releaseBox: OneShotRelease(release: { _ in }, modelId: "fixture"),
            toolHandler: handler)
        var result = Outcome()
        do {
            for try await event in stream {
                switch event {
                case .toolCall(let call): result.calls.append(call)
                case .content(let text): result.visible += text
                case .parsed(let value): result.visible += value.content
                default: break
                }
            }
        } catch { result.failure = try #require(error as? MultiModelBatchSchedulerEngineError) }
        return result
    }
}
#endif
