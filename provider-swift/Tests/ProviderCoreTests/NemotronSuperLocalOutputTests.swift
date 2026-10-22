import Foundation
import XCTest
import MLXLMCommon
import MLXLMServer
@testable import ProviderCore

/// Exact reasoning/tool/structured-output behavior of the Super output path,
/// following vLLM `ultra_v3` (streaming and complete) and `qwen3_coder` frames.
final class NemotronSuperLocalOutputTests: XCTestCase {
    private static let weather = #""tools":[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{"city":{"type":"string"},"days":{"type":"integer"}},"required":["city"]}}}]"#

    private func plan(_ extra: String = "") throws -> NemotronSuperRequestPlan {
        try .init(body: Data(("{\"model\":\"" + NemotronSuperLocalBinding.modelID
            + "\",\"messages\":[{\"role\":\"user\",\"content\":\"q\"}]"
            + (extra.isEmpty ? "" : "," + extra) + "}").utf8))
    }

    private func output(_ extra: String = "", streaming: Bool = true,
                        maximumBytes: Int = 1 << 20) throws -> NemotronSuperLocalOutput {
        try .init(plan: plan(extra), streaming: streaming, maximumBytes: maximumBytes)
    }

    /// R: reasoning delta, C: content delta, F: tool call (sorted JSON arguments).
    private func trace(_ events: [MLXServerGenerationEvent]) throws -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try events.map { event in
            switch event {
            case .parsed(let parsed):
                return [parsed.reasoningContent.map { "R:" + $0 }, parsed.content.isEmpty ? nil : "C:" + parsed.content]
                    .compactMap { $0 }.joined(separator: "|")
            case .content(let text): return "T:" + text
            case .toolCall(let call):
                return "F:" + call.function.name
                    + String(decoding: try encoder.encode(call.function.arguments), as: UTF8.self)
            case .info: return "I"
            }
        }
    }

    private func stream(_ output: inout NemotronSuperLocalOutput, _ chunks: [String]) throws -> [String] {
        var events: [MLXServerGenerationEvent] = []
        for chunk in chunks { events += try output.append(chunk) }
        return try trace(events + output.finish().events)
    }

    func testStreamingReasoningSplitsAcrossChunkBoundaries() throws {
        var output = try output()
        XCTAssertEqual(try stream(&output, ["Let me ", "think.</th", "ink>\n\nThe answer", " is 4."]),
                       ["R:Let me ", "R:think.", "C:\n\nThe answer", "C: is 4."])
        // A held marker prefix that does not complete is released as reasoning.
        var explicit = try self.output(#""chat_template_kwargs":{"enable_thinking":true}"#)
        XCTAssertEqual(try stream(&explicit, ["a<", "b"]), ["R:a", "R:<b"])
    }

    func testStreamingMarkersFollowTokenLevelReference() throws {
        var dropped = try output()
        XCTAssertEqual(try stream(&dropped, ["x<think>y</think>z"]), ["R:x", "R:y", "C:z"])
        var literal = try output()
        XCTAssertEqual(try stream(&literal, ["a</think>b<think>c</think>d"]), ["R:a", "C:b<think>c</think>d"])
        var unterminated = try output()
        XCTAssertEqual(try stream(&unterminated, ["still ", "thinking </thi"]),
                       ["R:still ", "R:thinking ", "R:</thi"])
        var off = try output(#""enable_thinking":false"#)
        XCTAssertEqual(try stream(&off, ["<think>no</think>", "yes"]), ["C:<think>no</think>", "C:yes"])
    }

    /// A combining mark after a marker's `>` starts the following text, as in
    /// the reference's code-point and marker-token matching.
    func testMarkersMatchBeforeACombiningMark() throws {
        var closed = try output()
        XCTAssertEqual(try stream(&closed, ["a</think>\u{301}b"]), ["R:a", "C:\u{301}b"])
        var opened = try output()
        XCTAssertEqual(try stream(&opened, ["x<think>\u{301}y"]), ["R:x", "R:\u{301}y"])
        var complete = try output(streaming: false)
        _ = try complete.append("<think>\u{301}r</think>\u{301}c")
        XCTAssertEqual(try complete.finish().result, .init(content: "\u{301}c", reasoning: "\u{301}r", calls: []))
    }

    func testCompleteResponseFollowsExtractReasoning() throws {
        func complete(_ text: String, _ extra: String = "") throws -> (String, String?, [String]) {
            var output = try output(extra, streaming: false)
            XCTAssertTrue(try output.append(text).isEmpty)
            let finished = try output.finish()
            return (finished.result.content, finished.result.reasoning, try trace(finished.events))
        }
        let opened = try complete("pre<think>\nreason</think>answer")
        XCTAssertEqual(opened.0, "answer")
        XCTAssertEqual(opened.1, "reason")
        XCTAssertEqual(opened.2, ["R:reason|C:answer"])
        let kept = try complete("\nr</think>\n\nc")
        XCTAssertEqual(kept.1, "\nr")
        XCTAssertEqual(kept.0, "\n\nc")
        let unterminated = try complete("still thinking")
        XCTAssertEqual(unterminated.2, ["R:still thinking"])
        XCTAssertEqual(unterminated.0, "")
        let forced = try complete("still thinking", #""chat_template_kwargs":{"force_nonempty_content":true}"#)
        XCTAssertEqual(forced.2, ["C:still thinking"])
        XCTAssertNil(forced.1)
        let off = try complete("<think>x</think>y", #""enable_thinking":false"#)
        XCTAssertEqual(off.2, ["C:<think>x</think>y"])
    }

    /// `force_nonempty_content` makes unterminated reasoning the answer. A
    /// stream (every coordinator request) keeps the streamed reasoning and
    /// repeats it as content at the end, as vLLM `nemotron_v3` does, through
    /// the same validators; a complete response moves it. Content after
    /// `</think>`, or no opt-in, promotes nothing.
    func testForceNonemptyContentPromotesUnterminatedReasoning() throws {
        let force = #""chat_template_kwargs":{"force_nonempty_content":true}"#
        var streamed = try output(force)
        var events = try streamed.append("still ") + streamed.append("thinking")
        let finished = try streamed.finish()
        events += finished.events
        XCTAssertEqual(try trace(events), ["R:still ", "R:thinking", "C:still thinking"])
        XCTAssertEqual(finished.result, .init(content: "still thinking", reasoning: "still thinking", calls: []))
        var answered = try output(force)
        XCTAssertEqual(try stream(&answered, ["r</think>", "c"]), ["R:r", "C:c"])
        var closedEmpty = try output(force)
        XCTAssertEqual(try stream(&closedEmpty, ["r</think>"]), ["R:r"])
        var notForced = try output()
        XCTAssertEqual(try stream(&notForced, ["still thinking"]), ["R:still thinking"])
        let json = force + #","response_format":{"type":"json_object"}"#
        var object = try output(json)
        XCTAssertEqual(try stream(&object, ["{\"a\":", "1}"]), [#"R:{"a":"#, "R:1}", #"C:{"a":1}"#])
        var notObject = try output(json)
        _ = try notObject.append("not json")
        XCTAssertThrowsError(try notObject.finish())
        var required = try output(force + "," + Self.weather + #","tool_choice":"required""#)
        _ = try required.append("no call")
        XCTAssertThrowsError(try required.finish()) {
            XCTAssertEqual($0 as? MultiModelBatchSchedulerEngineError, .toolChoiceViolation(
                "forced tool_choice produced visible text before a validated call"))
        }
        var complete = try output(force, streaming: false)
        _ = try complete.append("r</think>")
        XCTAssertEqual(try complete.finish().result, .init(content: "r", reasoning: nil, calls: []))
    }

    func testToolCallsAreParsedOnlyFromContentAndValidated() throws {
        var call = try output(Self.weather)
        XCTAssertEqual(try stream(&call, ["Need weather.</think>",
            "Checking.\n<tool_call>\n<function=get_weather>\n<parameter=city>\nParis\n</parameter>\n",
            "<parameter=days>\n3\n</parameter>\n</function>\n</tool_call>\n"]),
            ["R:Need weather.", "C:Checking.\n", "C:\n", #"F:get_weather{"city":"Paris","days":3}"#])
        var inReasoning = try output(Self.weather)
        XCTAssertEqual(try stream(&inReasoning, [
            "<tool_call>\n<function=get_weather>\n<parameter=city>\nX\n</parameter>\n</function>\n</tool_call></think>Done."]),
            ["R:<tool_call>\n<function=get_weather>\n<parameter=city>\nX\n</parameter>\n</function>\n</tool_call>",
             "C:Done."])
        // Text before a `<` survives even while the shared frame parser probes it.
        var plain = try output(Self.weather + #","enable_thinking":false"#)
        XCTAssertEqual(try stream(&plain, ["x <", "y", " a<to"]), ["C:x ", "C:<y", "C: a", "C:<to"])
        var unterminated = try output(Self.weather + #","enable_thinking":false"#)
        _ = try unterminated.append("a<tool_call>\n<function=get_weather>")
        XCTAssertThrowsError(try unterminated.finish())
        var complete = try output(Self.weather + #","enable_thinking":false"#, streaming: false)
        _ = try complete.append("<tool_call>\n<function=get_weather>\n<parameter=city>\nRome\n</parameter>\n</function>\n</tool_call>")
        XCTAssertEqual(try trace(complete.finish().events), [#"F:get_weather{"city":"Rome"}"#])
    }

    /// With no tool declared under auto choice the prompt offers no tools, so
    /// tool tags are answer text, as in the reference server.
    func testToolTagsAreTextWhenNoToolIsOffered() throws {
        let frame = "<tool_call>\n<function=get_weather>\n</function>\n</tool_call>"
        var streamed = try output(#""enable_thinking":false"#)
        XCTAssertEqual(try stream(&streamed, ["Write ", frame, " or <function=x>."]),
                       ["C:Write ", "C:" + frame, "C: or <function=x>."])
        for tools in ["", #""tools":[],"tool_choice":"auto""#] {
            var complete = try output(tools, streaming: false)
            _ = try complete.append("r</think>Write " + frame)
            XCTAssertEqual(try complete.finish().result, .init(content: "Write " + frame, reasoning: "r", calls: []))
        }
    }

    func testToolPolicyViolationsFailClosed() throws {
        let missing = "</think><tool_call>\n<function=get_weather>\n<parameter=days>\n2\n</parameter>\n</function>\n</tool_call>"
        var schema = try output(Self.weather)
        _ = try schema.append(missing)
        XCTAssertThrowsError(try schema.finish())
        var undeclared = try output(Self.weather)
        _ = try undeclared.append("</think><tool_call>\n<function=get_time>\n</function>\n</tool_call>")
        XCTAssertThrowsError(try undeclared.finish())
        let one = "<tool_call>\n<function=get_weather>\n<parameter=city>\nA\n</parameter>\n</function>\n</tool_call>"
        // `none` withholds the declarations, so any frame is undeclared, with
        // or without tools in the request.
        for tools in [Self.weather + ",", ""] {
            var none = try output(tools + #""tool_choice":"none""#)
            _ = try none.append("</think>" + one)
            XCTAssertThrowsError(try none.finish(), tools)
        }
        var parallel = try output(Self.weather + #","parallel_tool_calls":false"#)
        _ = try parallel.append("</think>" + one + one)
        XCTAssertThrowsError(try parallel.finish())
        var required = try output(Self.weather + #","tool_choice":"required""#)
        XCTAssertThrowsError(try required.append("</think>Sure, here it is."))
        var requiredMissing = try output(Self.weather + #","tool_choice":"required""#)
        _ = try requiredMissing.append("</think>")
        XCTAssertThrowsError(try requiredMissing.finish())
        var requiredValid = try output(Self.weather + #","tool_choice":"required""#)
        XCTAssertEqual(try stream(&requiredValid, ["plan</think>\n", one]),
                       ["R:plan", #"F:get_weather{"city":"A"}"#])
    }

    func testStructuredOutputIsWithheldValidatedAndNormalized() throws {
        var object = try output(#""response_format":{"type":"json_object"}"#)
        XCTAssertEqual(try object.append("Short plan.</think>"), [.parsed(.init(content: "", reasoningContent: "Short plan."))])
        XCTAssertTrue(try object.append("```json\n{\"ok\":").isEmpty)
        XCTAssertTrue(try object.append(" true}\n```").isEmpty)
        let finished = try object.finish()
        XCTAssertEqual(try trace(finished.events), [#"C:{"ok": true}"#])
        XCTAssertEqual(finished.result.content, #"{"ok": true}"#)
        let schema = #""enable_thinking":false,"response_format":{"type":"json_schema","json_schema":{"name":"r","schema":{"type":"object","properties":{"n":{"type":"integer"}},"required":["n"]}}}"#
        var valid = try output(schema)
        XCTAssertEqual(try stream(&valid, ["{\"n\": 3}"]), [#"C:{"n": 3}"#])
        var invalid = try output(schema)
        _ = try invalid.append("{\"n\": \"three\"}")
        XCTAssertThrowsError(try invalid.finish()) {
            XCTAssertEqual($0 as? MLXOpenAIServiceError,
                           .invalidResponseFormatOutput("value does not match schema type 'integer'"))
        }
        var notJSON = try output(#""enable_thinking":false,"response_format":{"type":"json_object"}"#, streaming: false)
        _ = try notJSON.append("not json")
        XCTAssertThrowsError(try notJSON.finish())
    }

    func testBoundedBufferAndSingleFinish() throws {
        var bounded = try output(maximumBytes: 4)
        XCTAssertThrowsError(try bounded.append("abcde"))
        XCTAssertThrowsError(try bounded.finish())
        var once = try output()
        _ = try once.finish()
        XCTAssertThrowsError(try once.finish())
    }

    func testPlanRefusesUnsupportedControlsAndFormatsOnce() throws {
        for extra in [#""logprobs":true"#, #""top_logprobs":2"#, #""prompt_cache_key":"k""#, #""n":2"#,
                      #""min_p":0.1"#, #""tool_call_parser":"json""#, #""reasoning_parser":"qwen3""#,
                      #""response_format":{"type":"json_object"},"# + Self.weather] {
            XCTAssertThrowsError(try plan(extra), extra)
        }
        let body = Data(("{\"model\":\"" + NemotronSuperLocalBinding.modelID
            + #"","messages":[{"role":"user","content":"q"}],"response_format":{"type":"json_object"}}"#).utf8)
        let direct = try NemotronSuperRequestPlan(body: body)
        let formatted = try OpenAIResponseFormatSupport.preparedRequest(ProviderLoop.decodeOpenAIRequest(body))
        let service = try NemotronSuperRequestPlan(body: body, formatted: formatted)
        XCTAssertEqual(direct.request.messages.count, 2)
        XCTAssertEqual(service.request.messages, direct.request.messages)
        XCTAssertEqual(direct.request.messages.first?.role, .system)
    }

    /// The coordinator normalizes a `{}` or boolean subschema into the
    /// reserved marker. Only a caller that trusts schema metadata (the
    /// coordinator path) admits it; a local request's marker is forged.
    func testSchemaMetadataIsAdmittedOnlyWhenTrusted() throws {
        func body(_ x: String) -> Data {
            Data(("{\"model\":\"" + NemotronSuperLocalBinding.modelID
                + #"","messages":[{"role":"user","content":"q"}],"tools":[{"type":"function","function":{"name":"set","parameters":{"type":"object","properties":{"x":"#
                + x + "}}}}]}").utf8)
        }
        let marked = body(#"{"type":"string","x-darkbloom-original-boolean-schema":true}"#)
        let forged = MultiModelBatchSchedulerEngineError.invalidToolPayload(
            "tool schema contains reserved internal metadata")
        XCTAssertThrowsError(try NemotronSuperRequestPlan(body: marked)) {
            XCTAssertEqual($0 as? MultiModelBatchSchedulerEngineError, forged)
        }
        let local = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: marked)
        XCTAssertThrowsError(try NemotronSuperRequestPlan(body: marked, formatted: local)) {
            XCTAssertEqual($0 as? MultiModelBatchSchedulerEngineError, forged)
        }
        let template = try XCTUnwrap(Data(base64Encoded: superImagePinnedTemplateBase64,
                                          options: .ignoreUnknownCharacters))
        let trusted = try NemotronSuperRequestPlan(body: marked, trustsSchemaMetadata: true)
        let prompt = SuperVideoTextTokenizer.text(try trusted.textPromptTokens(body: marked,
            templateBytes: template, tokenizer: SuperVideoTextTokenizer()))
        XCTAssertTrue(prompt.contains("<name>x</name>"), prompt)
        var output = try NemotronSuperLocalOutput(plan: trusted, streaming: true)
        XCTAssertEqual(try stream(&output, [
            "</think><tool_call>\n<function=set>\n<parameter=x>\nhi\n</parameter>\n</function>\n</tool_call>"]),
            [#"F:set{"x":"hi"}"#])
        // A local client's unmarked `{}` is decoded without normalization and serves.
        let plain = body("{}")
        let unmarked = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: plain)
        XCTAssertNoThrow(try NemotronSuperRequestPlan(body: plain, formatted: unmarked).textPromptTokens(
            body: plain, templateBytes: template, tokenizer: SuperVideoTextTokenizer()))
    }

    func testCollectorRejectsTruncationAndMissingTerminal() async throws {
        let missing = NemotronSuperOutputCollector(try output(streaming: false))
        await missing.accept(.chunk("partial"))
        do { _ = try await missing.finish(); XCTFail("missing terminal accepted") } catch {}
        let truncated = NemotronSuperOutputCollector(try output(streaming: false))
        await truncated.accept(.chunk("partial"))
        await truncated.accept(.info(promptTokens: 1, completionTokens: 1,
            tokensPerSecond: 0, finishReason: "length"))
        do { _ = try await truncated.finish(); XCTFail("truncated output accepted") } catch {}
        let complete = NemotronSuperOutputCollector(try output(streaming: false))
        await complete.accept(.chunk("r</think>"))
        await complete.accept(.chunk("ok"))
        await complete.accept(.info(promptTokens: 1, completionTokens: 2, tokensPerSecond: 0, finishReason: "stop"))
        let result = try await complete.finish()
        XCTAssertEqual(result, .init(content: "ok", reasoning: "r", calls: []))
    }
}
