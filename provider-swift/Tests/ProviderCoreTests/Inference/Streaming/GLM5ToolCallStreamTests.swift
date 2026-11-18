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
        /// Each exposed call's concatenated `arguments` fragments, decoded.
        var streamed: [[String: MLXLMCommon.JSONValue]] = []
        var names: [String] = []
        var failures: [ToolCallStreamFailure] = []
    }

    static func run(_ output: String, width: Int, names: Set<String> = ["write_file", "store"]) -> Rebuilt {
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
            case .call(let call): rebuilt.calls.append(call)
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
}
