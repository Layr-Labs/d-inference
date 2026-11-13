import Foundation
import MLXLMCommon
import MLXLMServer
import XCTest
@testable import ProviderCore

final class GPTOSSCommentaryConformanceTests: XCTestCase {
    private let flag = "DARKBLOOM_GPTOSS_COMMENTARY_CONTENT"
    private var previous: String?
    override func setUp() {
        super.setUp()
        previous = ProcessInfo.processInfo.environment[flag]
        setenv(flag, "1", 1)
    }
    override func tearDown() {
        if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        super.tearDown()
    }

    private func filtered(_ text: String, width: Int) -> String {
        var filter = HarmonyFinalHeaderFilter()
        let chars = Array(text)
        var result = ""
        for start in stride(from: 0, to: chars.count, by: width) {
            result += filter.ingest(String(chars[start..<min(start + width, chars.count)]))
        }
        return result + filter.finish()
    }

    func testRecipientlessPreambleReachesStreamingContent() {
        let output = "<|channel|>analysis<|message|>Need weather.<|end|><|start|>assistant"
            + "<|channel|>commentary<|message|>Checking Paris.<|end|>"
        for width in [1, 2, 3, 7, 4096] {
            var parser = StreamingReasoningParser(format: .harmony)
            var parsed = [ParsedReasoning]()
            for char in filtered(output, width: width) { parsed += parser.parse(String(char)) }
            parsed += parser.finish()
            XCTAssertEqual(parsed.map(\.content).joined(), "Checking Paris.")
            XCTAssertEqual(parsed.compactMap(\.reasoningContent).joined(), "Need weather.")
        }
    }

    func testRecipientlessPreambleReachesCollectedContent() {
        let output = "<|channel|>commentary<|message|>Checking Paris.<|end|>"
        XCTAssertEqual(ReasoningParser(format: .harmony).parse(filtered(output, width: 1)).content, "Checking Paris.")
    }

    func testToolRecipientsOnEitherSideOfChannelAreUnchanged() {
        for header in [
            "<|start|>assistant to=functions.get_weather<|channel|>commentary",
            "<|start|>assistant<|channel|>commentary to=functions.get_weather",
        ] {
            let output = header + "<|message|>{\"city\":\"Paris\"}<|call|>"
            for width in [1, 3, 4096] { XCTAssertEqual(filtered(output, width: width), output) }
        }
    }

    func testBodyMarkersOtherRolesAndOversizedHeadersStayLiteral() {
        let channel = "<|channel|>commentary<|message|>text"
        for output in [
            "<|start|>user" + channel,
            "<|start|>tool" + channel,
            "<|start|>assistant " + String(repeating: " ", count: 256) + channel,
            "<|channel|>final<|message|>Literal " + channel,
        ] {
            for width in [1, 3, 4096] { XCTAssertEqual(filtered(output, width: width), output) }
        }
        XCTAssertTrue(LaunchAgent.inferencePassthroughEnvKeys.contains(flag))
    }

    #if DEBUG
    func testPreambleArrivesBeforeTheToolThroughTheEngineStream() async throws {
        let body = Data(#"{"model":"gpt-oss-20b","messages":[{"role":"user","content":"Check Paris"}],"stream":true,"reasoning_parser":"harmony","tools":[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{"city":{"type":"string"}}}}}]}"#.utf8)
        var request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: body)
        request.streamToolCallDeltas = true
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gpt_oss")
        for recipient in [
            "assistant to=functions.get_weather<|channel|>commentary",
            "assistant<|channel|>commentary to=functions.get_weather",
        ] {
            let handler = try ToolStreamPreparation.makeHandler(request: request, prepared: prepared,
                modelType: "gpt_oss", streamToolCalls: true)
            let output = "<|channel|>commentary<|message|>Checking Paris.<|end|><|start|>"
                + recipient + "<|message|>{\"city\":\"Paris\"}<|call|>"
            let upstream = AsyncStream<GenerationEvent> { continuation in
                for char in output { continuation.yield(.chunk(String(char))) }
                continuation.yield(.info(promptTokens: 9, completionTokens: output.count,
                    tokensPerSecond: 0, finishReason: "stop"))
                continuation.finish()
            }
            let stream = try MultiModelBatchSchedulerEngine(registryProvider: { [:] })._testMakeEventStream(
                upstream: upstream, cancelUpstream: {}, prepared: prepared,
                releaseBox: OneShotRelease(release: { _ in }, modelId: request.model),
                toolHandler: handler, rewriteHarmonyFinalHeaders: true)
            var parser = StreamingReasoningParser(format: .harmony)
            var content = ""
            var calls = [ToolCall]()
            for try await event in stream {
                if case .content(let text) = event { content += parser.parse(text).map(\.content).joined() }
                if case .toolCallDelta(let delta) = event {
                    XCTAssertEqual(content, "Checking Paris.", "The preamble must precede the call")
                    if let call = delta.completed { calls.append(call) }
                }
            }
            content += parser.finish().map(\.content).joined()
            XCTAssertEqual(content, "Checking Paris.")
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls.first?.function.arguments["city"], .string("Paris"))
        }
    }
    #endif

    func testOffAndAbsentKeepCommentaryDropped() {
        let output = "<|channel|>commentary<|message|>Checking Paris.<|end|>"
        for value in ["0", "off", "false", "no"] {
            setenv(flag, value, 1)
            XCTAssertEqual(filtered(output, width: 1), output)
        }
        unsetenv(flag)
        XCTAssertEqual(filtered(output, width: 1), output)
    }
}
