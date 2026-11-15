import Foundation
import MLXLMCommon
import MLXLMServer
import XCTest
@testable import ProviderCore

/// Run with XCTest's process-isolated runner. Restore the rollout flag after
/// each test; Swift Testing suites execute in their separate runner.
final class QwenForcedThinkingConformanceTests: XCTestCase {
    private let flag = "DARKBLOOM_QWEN_FORCED_TOOL_THINKING"
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

    private func context(choice: String, reasoning: String, modelType: String = "qwen3_5_moe") throws -> [String: any Sendable]? {
        let body = Data("""
        {"model":"qwen3.6-35b-a3b-vl-mtp-mxfp8","messages":[{"role":"user","content":"Check Paris"}],
         "tools":[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false}}}],
         "tool_choice":\(choice),\(reasoning)}
        """.utf8)
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: body)
        let controls = try JSONDecoder().decode(ChatTemplateControls.self, from: body)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: modelType)
        return MultiModelBatchSchedulerEngine.templateAdditionalContext(for: request, controls: controls,
            modelType: modelType, requiresToolCall: prepared.requiresToolCall)
    }

    func testRequiredAndNamedCallsPreserveExplicitReasoning() throws {
        for type in ["qwen3_5", "qwen3_5_moe"] {
            for choice in [#""required""#, #"{"type":"function","function":{"name":"get_weather"}}"#] {
                let value = try context(choice: choice, reasoning: #""reasoning":{"enabled":true},"enable_thinking":false"#, modelType: type)
                XCTAssertEqual(value?["enable_thinking"] as? Bool, true)
            }
        }
    }

    func testNestedDisableAndNoToolChoiceRetainTheirMeaning() throws {
        XCTAssertEqual(try context(choice: #""required""#,
            reasoning: #""reasoning":{"enabled":false},"enable_thinking":true"#)?["enable_thinking"] as? Bool, false)
        XCTAssertEqual(try context(choice: #""auto""#,
            reasoning: #""reasoning":{"enabled":true}"#)?["enable_thinking"] as? Bool, true)
    }

    #if DEBUG
    func testRequiredAndNamedThinkingEndsWithAValidatedCall() async throws {
        let frame = "<tool_call><function=get_weather><parameter=city>Paris</parameter></function></tool_call>"
        for choice in [#""required""#, #"{"type":"function","function":{"name":"get_weather"}}"#] {
            for (parserName, closeThought) in [("qwen35", true), ("qwen35", false), ("xml_function", true)] {
                let body = Data("""
                {"model":"qwen3.6-35b-a3b-vl-mtp-mxfp8","messages":[{"role":"user","content":"Check Paris"}],
                 "tools":[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],
                 "tool_choice":\(choice),"reasoning":{"enabled":true},"stream":true,"tool_call_parser":"\(parserName)"}
                """.utf8)
                let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: body)
                let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "qwen3_5_moe")
                let handler = try ToolStreamPreparation.makeHandler(request: request, prepared: prepared,
                    modelType: "qwen3_5_moe", streamToolCalls: true)
                let output = "Find the weather." + (closeThought ? "</think>" : "") + frame
                let upstream = AsyncStream<GenerationEvent> { continuation in
                    for char in output { continuation.yield(.chunk(String(char))) }
                    continuation.yield(.info(promptTokens: 9, completionTokens: output.count,
                        tokensPerSecond: 0, finishReason: "stop"))
                    continuation.finish()
                }
                let stream = try MultiModelBatchSchedulerEngine(registryProvider: { [:] })._testMakeEventStream(
                    upstream: upstream, cancelUpstream: {}, prepared: prepared,
                    releaseBox: OneShotRelease(release: { _ in }, modelId: request.model),
                    reasoningPrefix: "<think>", toolHandler: handler,
                    nativeReasoningPrefix: Qwen35TemplateFix.routesReasoningBeforeTools(
                        format: handler?.format, requiresToolCall: prepared.requiresToolCall,
                        context: .init(modelId: request.model, modelType: "qwen3_5_moe")) ? "<think>" : nil,
                    promotesTrailingReasoningCalls: true)
                var reasoning = ""
                var calls = [ToolCall]()
                for try await event in stream {
                    if case .parsed(let part) = event {
                        reasoning += part.reasoningContent ?? ""
                        XCTAssertTrue(part.content.isEmpty)
                    }
                    if case .toolCall(let call) = event { calls.append(call) }
                }
                XCTAssertEqual(reasoning, "Find the weather." + (closeThought ? "" : frame))
                XCTAssertEqual(calls.count, 1)
                XCTAssertEqual(calls.first?.function.name, "get_weather")
                XCTAssertEqual(calls.first?.function.arguments["city"], .string("Paris"))
            }
        }
    }
    #endif

    func testFlagIsFamilyScopedAndReachesTheDaemon() {
        XCTAssertTrue(LaunchAgent.inferencePassthroughEnvKeys.contains(Qwen35TemplateFix.forcedThinkingEnvironmentKey))
        for type in ["qwen3_vl_moe", "prism_hadamard_qwen35", "gpt_oss", "mimo_v2"] {
            XCTAssertFalse(Qwen35TemplateFix.preservesForcedThinking(
                .init(modelId: "qwen3.6-35b-a3b-vl-mtp-mxfp8", modelType: type)))
        }
    }

    func testSwitchOffPreservesForcedThinkingOff() throws {
        for value in ["0", "off", "false", "no"] {
            setenv(flag, value, 1)
            XCTAssertEqual(try context(choice: #""required""#,
                reasoning: #""reasoning":{"enabled":true}"#)?["enable_thinking"] as? Bool, false)
        }
        unsetenv(flag)
        XCTAssertEqual(try context(choice: #""required""#,
            reasoning: #""reasoning":{"enabled":true}"#)?["enable_thinking"] as? Bool, false)
    }
}
