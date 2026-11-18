import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// `GLM5ToolCallStream` against the SDK parser: whatever the chunking, the
/// calls a client rebuilds from the segments are the calls `parseEOS` reads
/// from the same output, and text outside frames is kept in order.
@Suite("GLM tool call stream")
struct GLM5ToolCallStreamTests {
    static let tools: [[String: any Sendable]] = [
        ["type": "function", "function": ["name": "write_file", "parameters": [
            "type": "object", "properties": ["path": ["type": "string"], "content": ["type": "string"]],
        ] as [String: any Sendable]] as [String: any Sendable]],
        ["type": "function", "function": ["name": "store", "parameters": [
            "type": "object", "properties": [
                "doc": ["type": "object"], "count": ["type": "integer"], "tags": ["type": ["array", "null"]],
                "note": ["type": "string"],
            ] as [String: any Sendable],
        ] as [String: any Sendable]] as [String: any Sendable]],
    ]

    struct Rebuilt: Equatable {
        var text = ""
        var calls: [ToolCall] = []
        /// Each call's concatenated `arguments` fragments, decoded.
        var streamed: [[String: MLXLMCommon.JSONValue]] = []
        var names: [String] = []
        var failures: [ToolCallStreamFailure] = []
    }

    static func run(_ output: String, width: Int, names: Set<String> = ["write_file", "store"],
                    tools: [[String: any Sendable]] = tools) -> Rebuilt {
        let stream = GLM5ToolCallStream(tools: tools, exposesName: { names.contains($0) })
        var segments: [ToolCallStreamSegment] = []
        var characters = output[...]
        while !characters.isEmpty {
            segments += stream.process(String(characters.prefix(width)))
            characters = characters.dropFirst(width)
        }
        segments += stream.finish()
        var rebuilt = Rebuilt()
        var arguments = ""
        for segment in segments {
            switch segment {
            case .text(let text): rebuilt.text += text
            case .callStarted(let name):
                rebuilt.names.append(name)
                arguments = ""
            case .callArguments(let fragment): arguments += fragment
            case .callCompleted(let call, let remainder):
                arguments += remainder
                rebuilt.calls.append(call)
                rebuilt.streamed.append(
                    (try? JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(arguments.utf8))) ?? [:])
            case .call(let call):
                // Sent whole: its arguments are the call's own.
                rebuilt.calls.append(call)
                rebuilt.streamed.append(call.function.arguments)
            case .callFailed(let failure): rebuilt.failures.append(failure)
            }
        }
        return rebuilt
    }

    static let frames = [
        "<tool_call>write_file<arg_key>path</arg_key><arg_value>a.py</arg_value>"
            + "<arg_key>content</arg_key><arg_value>print(\"hi\")\n\tx = a < b\\n é 🙂\n</arg_value></tool_call>",
        "<tool_call>write_file\n<arg_key>content</arg_key><arg_value></arg_value>\n"
            + "<arg_key>path</arg_key><arg_value> spaced </arg_value>\n</tool_call>",
        "<tool_call>store<arg_key>note</arg_key><arg_value>first</arg_value><arg_key>doc</arg_key>"
            + #"<arg_value> {"a":[1,2,{"b":"</arg_value></tool_call>"}],"c":null} </arg_value>"#
            + "<arg_key>count</arg_key><arg_value>42</arg_value><arg_key>tags</arg_key><arg_value>null</arg_value></tool_call>",
        // A typed value quoting a key of a typed parameter: data, also when
        // another frame follows (REVIEW-2267 F1).
        "<tool_call>store<arg_key>doc</arg_key>"
            + #"<arg_value>{"x":"<arg_key>doc</arg_key><arg_value>["}</arg_value></tool_call>"#,
        "<tool_call>store<arg_key>doc</arg_key><arg_value>not json</arg_value></tool_call>",
        "<tool_call>store</tool_call>",
    ]

    @Test(arguments: [1, 2, 3, 7, 64, 4096])
    func everyChunkingRebuildsTheParsersCalls(width: Int) throws {
        let parser = GLM5ToolCallParser()
        for frame in Self.frames {
            let expected = parser.parseEOS(frame, tools: Self.tools)
            #expect(expected.count == 1, "\(frame)")
            let run = Self.run(frame, width: width)
            #expect(run.calls == expected, "\(width): \(frame)")
            #expect(run.failures.isEmpty && run.text.isEmpty, "\(width): \(frame)")
            for (call, streamed) in zip(run.calls, run.streamed) {
                #expect(streamed == call.function.arguments, "\(width): \(frame)")
            }
        }
        let all = Self.frames.joined(separator: "\n")
        let batch = parser.parseEOS(all, tools: Self.tools)
        let run = Self.run("Before <tool_call> x.\n" + all + "\nAfter.", width: width)
        #expect(run.calls == batch)
        // Whitespace between calls is framing; before other text it is text.
        #expect(run.text == "Before <tool_call> x.\n" + "\nAfter.")
        #expect(Self.run(all + "\n \n", width: width).text.isEmpty)
    }

    /// The name leaves first and a string value streams before its frame closes.
    @Test func stringValuesStreamBeforeTheFrameCloses() {
        let stream = GLM5ToolCallStream(tools: Self.tools, exposesName: { _ in true })
        let head = stream.process("<tool_call>write_file<arg_key>content</arg_key><arg_value>line one\nline")
        #expect(head == [.callStarted(name: "write_file"), .callArguments(#"{"content":""#),
                         .callArguments(#"line one\nline"#)])
        #expect(stream.process(" two</arg_") == [.callArguments(" two")])
    }

    /// A name the request does not let stream, or does not declare, is never
    /// exposed: it completes in one piece, or is text when it does not parse.
    @Test func unexposedFramesCompleteWholeOrStayText() throws {
        let frame = Self.frames[0]
        let hidden = Self.run(frame, width: 5, names: [])
        #expect(hidden.names.isEmpty && hidden.calls.count == 1 && hidden.text.isEmpty)
        let undeclared = "<tool_call>nope<arg_key>a</arg_key><arg_value>b</arg_value></tool_call>"
        let run = Self.run(undeclared + "tail", width: 3)
        #expect(run.calls.isEmpty && run.names.isEmpty && run.failures.isEmpty)
        #expect(run.text == undeclared + "tail")
    }

    @Test(arguments: [
        ("<tool_call>write_file<arg_key>path</arg_key><arg_value>a", ToolCallStreamFailure.unterminated),
        ("<tool_call>write_file<arg_key>path</arg_key><arg_value>a<tool_call>b</arg_value></tool_call>", .malformed),
        ("<tool_call>write_file<arg_key>path</arg_key><arg_value>a</arg_value>x</tool_call>", .malformed),
        ("<tool_call>write_file<arg_key>p<a</arg_key>", .malformed),
        ("<tool_call>write_file<arg_key>path</arg_key> <arg_value>a</arg_value></tool_call>", .malformed),
    ])
    func exposedFramesThatBreakTheGrammarFail(output: String, failure: ToolCallStreamFailure) {
        for width in [1, 4, 4096] {
            let later = failure == .unterminated ? "" : "<tool_call>write_file</tool_call>"
            let run = Self.run(output + later, width: width)
            #expect(run.names == ["write_file"], "\(width)")
            #expect(run.failures == [failure], "\(width)")
            #expect(run.calls.isEmpty, "\(width): the failed frame owns the rest")
        }
    }

    /// The quoted key of F1 with another call after it: both are the parse's.
    @Test(arguments: [1, 7, 4096])
    func aQuotedKeyInATypedValueDoesNotHoldTheFrameOpen(width: Int) {
        let quoted = Self.frames[3]
        let second = "<tool_call>store<arg_key>note</arg_key><arg_value>n</arg_value></tool_call>"
        for output in [quoted + "\n" + second, quoted + "\nSaid \"done\"."] {
            let expected = GLM5ToolCallParser().parseEOS(quoted, tools: Self.tools)
                + GLM5ToolCallParser().parseEOS(second, tools: Self.tools)
            let run = Self.run(output, width: width)
            #expect(run.failures.isEmpty, "\(width): \(output)")
            #expect(run.calls == (output.hasSuffix(second) ? expected : Array(expected.prefix(1))), "\(width)")
        }
    }

    /// The SDK parser's 1 MiB bound, per frame: an exposed frame past it
    /// fails `malformed`; one never exposed is text, and what follows is read
    /// again (REVIEW-2267 F7c).
    @Test func framesPastTheBoundFailOrStayText() {
        let big = String(repeating: "x", count: (1 << 20) + 100_000)
        let exposed = Self.run("<tool_call>write_file<arg_key>content</arg_key><arg_value>" + big, width: 1 << 16)
        #expect(exposed.names == ["write_file"] && exposed.failures == [.malformed] && exposed.calls.isEmpty)
        let hidden = "<tool_call>store<arg_key>doc</arg_key><arg_value>" + big
        let after = "<tool_call>store</tool_call>"
        let run = Self.run(hidden + "</arg_value></tool_call>" + after, width: 1 << 16, names: [])
        #expect(run.failures.isEmpty && run.names.isEmpty)
        #expect(run.calls == GLM5ToolCallParser().parseEOS(after, tools: Self.tools))
        #expect(run.text == hidden + "</arg_value></tool_call>")
    }

    /// With `DARKBLOOM_GRAMMAR_ONLY_TOOL_PARSING` off the parser checks the
    /// schema: an exposed call that misses it fails `malformed` at its close;
    /// grammar-only, the same frame is the call (REVIEW-2267 F7d).
    @Test func checkingSchemasAnExposedCallThatMissesThemFails() {
        let tools: [[String: any Sendable]] = [["type": "function", "function": ["name": "write_file", "parameters": [
            "type": "object", "properties": ["path": ["type": "string"], "content": ["type": "string"]],
            "required": ["path", "content"],
        ] as [String: any Sendable]] as [String: any Sendable]]]
        let output = "<tool_call>write_file<arg_key>path</arg_key><arg_value>a.py</arg_value></tool_call>"
        for grammarOnly in [true, false] {
            let stream = GLM5ToolCallStream(tools: tools, exposesName: { _ in true }, grammarOnly: grammarOnly)
            let segments = stream.process(output) + stream.finish()
            #expect(segments.first == .callStarted(name: "write_file"))
            let failed = segments.contains(.callFailed(.malformed))
            #expect(failed == !grammarOnly, "grammarOnly \(grammarOnly): \(segments)")
            #expect(GLM5ToolCallParser(grammarOnly: grammarOnly).parseEOS(output, tools: tools).isEmpty == failed)
        }
    }

    static let differentialTools: [[String: any Sendable]] = [
        ["type": "function", "function": ["name": "store", "parameters": [
            "type": "object", "properties": [
                "doc": ["type": "object"], "list": ["type": "array"], "count": ["type": "integer"],
                "note": ["type": "string"], "any": [:] as [String: any Sendable],
                "mix": ["type": ["string", "integer"]],
            ] as [String: any Sendable],
        ] as [String: any Sendable]] as [String: any Sendable]],
    ]

    /// Random outputs of one to three frames whose typed values quote the
    /// frame tags (REVIEW-2267's probe, seeded): whenever `parseEOS` reads
    /// every frame, the stream returns the same calls, with no failure and no
    /// text, and the fragments it streamed decode to each call's arguments.
    @Test func randomFramesQuotingTheirTagsMatchParseEOS() {
        var random = SplitMix64(seed: 0x2267)
        let strings = ["plain", "a < b", "é🙂", " spaced ", "", "line\nline", #"{"not":"json"}"#, "null", "42"]
        let tags = ["</arg_value>", "</tool_call>", "<tool_call>", "<arg_key>doc</arg_key><arg_value>",
                    "<arg_key>list</arg_key><arg_value>", "<arg_key>count</arg_key><arg_value>",
                    "<arg_key>note</arg_key><arg_value>", "[", "{", #"\""#, "x"]
        func jsonString() -> String {
            let inner = (0 ..< Int.random(in: 0 ... 4, using: &random)).map { _ in
                let tag = tags.randomElement(using: &random)!
                return tag == #"\""# ? tag : tag.replacingOccurrences(of: "\"", with: #"\""#)
            }
            return "\"" + inner.joined() + "\""
        }
        func typedValue(_ depth: Int = 0) -> String {
            switch Int.random(in: 0 ... 4, using: &random) {
            case 1 where depth < 3:
                return "[" + (0 ..< Int.random(in: 0 ... 3, using: &random)).map { _ in typedValue(depth + 1) }
                    .joined(separator: ",") + "]"
            case 2 where depth < 3:
                return "{" + (0 ..< Int.random(in: 0 ... 3, using: &random))
                    .map { "\"k\($0)\":" + typedValue(depth + 1) }.joined(separator: ",") + "}"
            case 3: return ["1", "-2.5", "true", "null"].randomElement(using: &random)!
            default: return jsonString()
            }
        }
        let parser = GLM5ToolCallParser()
        var compared = 0
        for _ in 0 ..< 2000 {
            let frames = (0 ..< Int.random(in: 1 ... 3, using: &random)).map { _ in
                var used: Set<String> = []
                var arguments = ""
                for _ in 0 ..< Int.random(in: 0 ... 3, using: &random) {
                    let key = ["doc", "list", "note", "count", "any", "mix"].randomElement(using: &random)!
                    guard used.insert(key).inserted else { continue }
                    let value = switch key {
                    case "doc": #"{"v":"# + typedValue() + "}"
                    case "list": "[" + typedValue() + "]"
                    case "count": ["1", "7", "x"].randomElement(using: &random)!
                    case "note": strings.randomElement(using: &random)!
                    default: Bool.random(using: &random) ? typedValue() : strings.randomElement(using: &random)!
                    }
                    arguments += "<arg_key>\(key)</arg_key><arg_value>\(value)</arg_value>"
                }
                return "<tool_call>store" + arguments + "</tool_call>"
            }
            let output = frames.joined(separator: "\n")
            let expected = parser.parseEOS(output, tools: Self.differentialTools)
            guard expected.count == frames.count else { continue }
            compared += 1
            for width in [1, 5, 4096] {
                let run = Self.run(output, width: width, tools: Self.differentialTools)
                #expect(run.calls == expected && run.failures.isEmpty && run.text.isEmpty, "\(width): \(output)")
                for (call, streamed) in zip(run.calls, run.streamed) {
                    #expect(streamed == call.function.arguments, "\(width): \(output)")
                }
            }
        }
        // The seed keeps the set fixed; most outputs parse.
        #expect(compared > 1000)
    }
}

/// SplitMix64: a fixed sequence for a fixed seed.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
