import Foundation
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
