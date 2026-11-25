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

    // MARK: - Rules

    struct Served {
        var events: [MLXServerGenerationEvent] = []
        var error: Error?
        var deltas: [ServerToolCallDelta] { NemotronSuperStreamedToolCallTests.deltas(events) }
        /// Calls a client rebuilds: streamed by index, or whole.
        var calls: [(name: String, arguments: String)] {
            var calls: [(name: String, arguments: String)] = []
            for event in events {
                switch event {
                case .toolCallDelta(let delta):
                    if delta.index == calls.count { calls.append((delta.name ?? "", "")) }
                    calls[delta.index].arguments += delta.arguments
                case .toolCall(let call):
                    let data = try! JSONEncoder().encode(call.function.arguments)
                    calls.append((call.function.name, String(decoding: data, as: UTF8.self)))
                default: break
                }
            }
            return calls
        }
        var content: String {
            events.reduce(into: "") { if case .parsed(let p) = $1 { $0 += p.content } }
        }
        var reasoning: String {
            events.reduce(into: "") { if case .parsed(let p) = $1 { $0 += p.reasoningContent ?? "" } }
        }
        var check: ToolNoncomplianceCheck? { error.flatMap(classifyToolNoncomplianceCheck) }
    }

    static func serve(_ text: String, _ extra: String = "", clientStreams: Bool = true,
                      cutAtLimit: Bool = false, truncated: Bool? = nil, streamNative: Bool = true,
                      streamForced: Bool = true) throws -> Served {
        var output = try NemotronSuperLocalOutput(plan: plan(extra, clientStreams: clientStreams), streaming: true,
            streamNativeToolCalls: streamNative, streamForcedToolCalls: streamForced)
        var served = Served()
        do {
            for character in text { served.events += try output.append(String(character)) }
            served.events += try output.finish(cutAtLimit: cutAtLimit, truncated: truncated).events
        } catch {
            served.error = error
        }
        return served
    }

    static let required = #""tool_choice":"required""#
    static let off = #""chat_template_kwargs":{"enable_thinking":false}"#

    /// A client that does not stream, and the switch off, keep the withheld
    /// whole call; the call is the one a streaming client rebuilds.
    @Test(arguments: ["", required])
    func clientsThatDoNotStreamAndTheSwitchKeepTheWholeCall(choice: String) throws {
        let text = "Done.</think>" + Self.frame("get_weather", [("city", "Paris"), ("days", "3")])
        let streamed = try Self.serve(text, choice)
        let whole = try Self.serve(text, choice, clientStreams: false)
        let off = try Self.serve(text, choice, streamNative: false)
        #expect(streamed.error == nil && whole.error == nil && off.error == nil)
        #expect(streamed.deltas.count > 1)
        for held in [whole, off] {
            #expect(held.deltas.isEmpty)
        }
        // `DARKBLOOM_TTFT_STREAM_FORCED_TOOL_CALLS` off withholds a forced
        // call only; `auto` calls keep streaming.
        let forcedOff = try Self.serve(text, choice, streamForced: false)
        #expect(forcedOff.error == nil)
        #expect(choice.isEmpty ? forcedOff.deltas.count > 1 : forcedOff.deltas.isEmpty)
        for served in [streamed, whole, off, forcedOff] {
            #expect(served.calls.map(\.name) == ["get_weather"])
            #expect(try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self,
                from: Data(served.calls[0].arguments.utf8)) == ["city": .string("Paris"), "days": .int(3)])
        }
    }

    /// Forced rules while streaming: text refused, framing whitespace kept
    /// out, a call that fails after it started refused, no call refused,
    /// another function never exposed, and a cut ends with the call open.
    @Test func forcedSuperStreamsKeepTheForcedRules() throws {
        let call = Self.frame("get_weather", [("city", "Paris")])
        let text = try Self.serve("Sure! " + call, Self.required + "," + Self.off)
        #expect(text.error.map { "\($0)".contains("visible text") } == true, "\(String(describing: text.error))")
        let spaced = try Self.serve("\n" + call + "\n", Self.required + "," + Self.off)
        #expect(spaced.error == nil && spaced.calls.map(\.name) == ["get_weather"])
        let head = String(Self.frame("write_file", [("path", "a.py"), ("content", "print(")]).dropLast(30))
        let open = try Self.serve(head, Self.required + "," + Self.off)
        #expect(open.check == .unterminated, "\(String(describing: open.error))")
        #expect(open.calls.first?.name == "write_file", "it had started streaming")
        let none = try Self.serve("\n", Self.required + "," + Self.off)
        #expect(none.error != nil)
        let named = try Self.serve(Self.frame("write_file", [("path", "a"), ("content", "x")]),
            #""tool_choice":{"type":"function","function":{"name":"get_weather"}},"# + Self.off)
        #expect(named.error != nil && named.calls.isEmpty)
        let cut = try Self.serve(head, Self.required + "," + Self.off, cutAtLimit: true)
        #expect(cut.error == nil, "\(String(describing: cut.error))")
        #expect(cut.calls.first?.name == "write_file" && !cut.deltas.contains { $0.completed != nil })
    }

    /// `auto`: a call that fails after it started is refused, never closed.
    @Test func autoSuperCallsThatFailAfterTheyStartedAreRefused() throws {
        let duplicate = try Self.serve(Self.frame("write_file", [("path", "a"), ("path", "b"), ("content", "x")]), Self.off)
        #expect(duplicate.check == .malformed, "\(String(describing: duplicate.error))")
        #expect(!duplicate.deltas.contains { $0.completed != nil })
    }

    /// Reasoning leaves first; text around `auto` calls stays text; two calls
    /// stream with their own indexes and `parallel_tool_calls: false` keeps
    /// the first, as the withheld path does.
    @Test func superReasoningTextAndTwoCalls() throws {
        let call = Self.frame("get_weather", [("city", "Paris")])
        let second = Self.frame("write_file", [("path", "a"), ("content", "x")])
        let reasoned = try Self.serve("Checking.</think>" + call)
        #expect(reasoned.reasoning == "Checking." && reasoned.calls.map(\.name) == ["get_weather"])
        let firstDelta = reasoned.events.firstIndex { if case .toolCallDelta = $0 { true } else { false } }!
        #expect(reasoned.events[..<firstDelta].contains { if case .parsed(let p) = $0 { p.reasoningContent != nil } else { false } })
        let texted = try Self.serve("Looking it up.\n" + call + "\nDone.", Self.off)
        let textedWhole = try Self.serve("Looking it up.\n" + call + "\nDone.", Self.off, clientStreams: false)
        #expect(texted.error == nil && texted.content == textedWhole.content, "\(texted.content)")
        let both = try Self.serve(call + "\n" + second, Self.off)
        #expect(both.error == nil && both.calls.map(\.name) == ["get_weather", "write_file"])
        let first = try Self.serve(call + "\n" + second, Self.off + #","parallel_tool_calls":false"#)
        let firstWhole = try Self.serve(call + "\n" + second, Self.off + #","parallel_tool_calls":false"#,
            clientStreams: false)
        #expect(first.calls.map(\.name) == firstWhole.calls.map(\.name))
        #expect((first.error == nil) == (firstWhole.error == nil))
    }

    /// Super's owner refuses a frame that did not parse, and drops one a cut
    /// left open. A client that streams gets the same outcome as one that
    /// does not: no frame text leaves as content, and the end text is the
    /// same `.parsed` content.
    struct Unparsed: CustomTestStringConvertible, Sendable {
        let testDescription: String
        let text: String
        var cutAtLimit = false
        let refused: Bool

        static let all = [
            Unparsed(testDescription: "JSON-dialect frame",
                text: "Hi.\n<tool_call>\n{\"name\":\"get_weather\",\"arguments\":{\"city\":\"Paris\"}}\n</tool_call>",
                refused: true),
            Unparsed(testDescription: "unexposed frame left open", text: "Hi.\n<tool_call>\n<function=get_wea",
                refused: true),
            Unparsed(testDescription: "unexposed frame at a cut", text: "Hi.\n<tool_call>\n<function=get_wea",
                cutAtLimit: true, refused: false),
            Unparsed(testDescription: "bare function frame left open", text: "Hi.\n<function=get_wea",
                refused: true),
            Unparsed(testDescription: "a held tag prefix", text: "Hi. 1 <", refused: false),
        ]
    }

    @Test(arguments: Unparsed.all)
    func unparsedSuperFramesEndAsTheyDoWithheld(frame: Unparsed) throws {
        let streamed = try Self.serve(frame.text, Self.off, cutAtLimit: frame.cutAtLimit)
        let whole = try Self.serve(frame.text, Self.off, clientStreams: false, cutAtLimit: frame.cutAtLimit)
        #expect((streamed.error as? NemotronSuperLocalOutput.Failure) == (whole.error as? NemotronSuperLocalOutput.Failure),
            "\(String(describing: streamed.error)) vs \(String(describing: whole.error))")
        #expect((streamed.error != nil) == frame.refused, "\(String(describing: streamed.error))")
        #expect(!frame.refused || streamed.error as? NemotronSuperLocalOutput.Failure == .malformedToolFrame)
        #expect(streamed.content == whole.content, "\(streamed.content) vs \(whole.content)")
        #expect(!streamed.content.contains("<tool_call>") && !streamed.content.contains("<function="))
        #expect(streamed.deltas.isEmpty)
        #expect(!streamed.events.contains { if case .content = $0 { true } else { false } },
            "Super's text leaves as native content deltas")
    }

    /// `length` without a cut (`DARKBLOOM_LENGTH_FINISH_AT_LIMIT` off): an
    /// exposed call left open stays truncated, as on the scheduler's streamed
    /// terminal, instead of being refused as unterminated.
    @Test func aLengthStopLeavesAnExposedCallTruncated() throws {
        let head = String(Self.frame("write_file", [("path", "a.py"), ("content", "print(")]).dropLast(30))
        let truncated = try Self.serve(head, Self.off, truncated: true)
        #expect(truncated.error == nil, "\(String(describing: truncated.error))")
        #expect(truncated.calls.first?.name == "write_file" && !truncated.deltas.contains { $0.completed != nil })
        let stopped = try Self.serve(head, Self.off)
        #expect(stopped.check == .unterminated, "\(String(describing: stopped.error))")
    }

    /// `force_nonempty_content`: a call in a thought left open at the end is
    /// promoted to the answer, and streams as the withheld path returns it.
    @Test func aCallPromotedFromAnOpenThoughtMatchesTheWithheldOne() throws {
        let force = #""chat_template_kwargs":{"force_nonempty_content":true}"#
        let text = "Calling it.\n" + Self.frame("get_weather", [("city", "Paris")])
        let streamed = try Self.serve(text, force)
        let whole = try Self.serve(text, force, clientStreams: false)
        #expect(streamed.error == nil && whole.error == nil,
            "\(String(describing: streamed.error ?? whole.error))")
        #expect(streamed.calls.map(\.name) == ["get_weather"])
        #expect(streamed.calls.map(\.name) == whole.calls.map(\.name))
        #expect(streamed.calls.map(\.arguments) == whole.calls.map(\.arguments))
    }
}
