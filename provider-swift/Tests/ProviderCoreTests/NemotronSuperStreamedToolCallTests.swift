import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Nemotron 3.5 Super serves through its own owner (`NemotronSuperLocalOutput`),
/// not the scheduler's router: its tool calls must reach a client that
/// streams while they are generated too, under the same rules as the other
/// streamed families.
@Suite("Streamed Nemotron Super tool calls")
struct NemotronSuperStreamedToolCallTests {
    static let tools = #""tools":[{"type":"function","function":{"name":"write_file","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}},{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{"city":{"type":"string"},"days":{"type":"integer"}},"required":["city"]}}}]"#

    /// The plan as the chat route makes it: the body is the client's own,
    /// and `formatted` is the request `MLXOpenAIService` hands the engine
    /// (a stream with tool-call deltas on the coordinator path).
    static func plan(_ extra: String = "", clientStreams: Bool = true) throws -> NemotronSuperRequestPlan {
        let body = Data(("{\"model\":\"" + NemotronSuperLocalBinding.modelID
            + "\",\"messages\":[{\"role\":\"user\",\"content\":\"q\"}],\"stream\":\(clientStreams),"
            + tools + (extra.isEmpty ? "" : "," + extra) + "}").utf8)
        var formatted = try OpenAIResponseFormatSupport.preparedRequest(ProviderLoop.decodeOpenAIRequest(body))
        formatted.stream = true
        formatted.streamToolCallDeltas = true
        return try NemotronSuperRequestPlan(body: body, formatted: formatted)
    }

    static func frame(_ name: String, _ parameters: [(String, String)]) -> String {
        "<tool_call>\n<function=\(name)>\n"
            + parameters.map { "<parameter=\($0.0)>\n\($0.1)\n</parameter>\n" }.joined()
            + "</function>\n</tool_call>"
    }

    static func deltas(_ events: [MLXServerGenerationEvent]) -> [ServerToolCallDelta] {
        events.compactMap { if case .toolCallDelta(let delta) = $0 { delta } else { nil } }
    }

    /// A long Super tool answer held back every byte until generation ended.
    /// Its name must leave while the arguments are still being generated.
    @Test(arguments: [#""tool_choice":"auto""#, #""tool_choice":"required""#,
                      #""tool_choice":{"type":"function","function":{"name":"write_file"}}"#])
    func longSuperToolAnswersLeaveBeforeTheirFrameCloses(choice: String) throws {
        var output = try NemotronSuperLocalOutput(plan: Self.plan(choice), streaming: true)
        let content = String(repeating: "print('long answer')\n", count: 40)
        let text = "Thinking.</think>" + Self.frame("write_file", [("path", "long.py"), ("content", content)])
        let split = text.index(text.endIndex, offsetBy: -(content.count + 20))
        var early: [MLXServerGenerationEvent] = []
        for character in text[..<split] { early += try output.append(String(character)) }
        #expect(Self.deltas(early).first?.name == "write_file",
            "the call's first content must leave before its frame closes")
        var events = early
        for character in text[split...] { events += try output.append(String(character)) }
        events += try output.finish().events
        let deltas = Self.deltas(events)
        let arguments = deltas.map(\.arguments).joined()
        #expect(try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(arguments.utf8))
            == ["path": .string("long.py"), "content": .string(content)])
        #expect(deltas.contains { $0.completed != nil })
        #expect(!events.contains { if case .toolCall = $0 { true } else { false } }, "the call left as fragments")
    }
}
