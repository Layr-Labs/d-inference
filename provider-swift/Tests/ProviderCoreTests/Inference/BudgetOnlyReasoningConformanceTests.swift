import Foundation
import MLXLMServer
import XCTest
@testable import ProviderCore

final class BudgetOnlyReasoningConformanceTests: XCTestCase {
    private let flag = "DARKBLOOM_NATIVE_REASONING_BUDGET"
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

    private func body(_ budget: String) -> Data {
        Data("""
        {"model":"mimo-v2.6-flash-mopd","messages":[{"role":"user","content":"Hello"}],
         "reasoning":{"max_tokens":\(budget)}}
        """.utf8)
    }

    func testSuperBudgetOnlyEnablesThinking() throws {
        let data = body("512")
        let controls = try NemotronSuperPromptContract.controls(body: data)
        XCTAssertTrue(controls.enableThinking)
        XCTAssertEqual(try JSONDecoder().decode(ChatTemplateControls.self, from: data).reasoningBudgetTokens, 512)
    }

    func testMiMoBudgetOnlyIsAcceptedAndRetainsBudget() throws {
        let data = body("512")
        try MiMoV26TemplateFix.validateRawControls(data)
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: data)
        let controls = try JSONDecoder().decode(ChatTemplateControls.self, from: data)
        XCTAssertTrue(try MiMoV26TemplateFix.effectiveThinkingEnabled(request: request, controls: controls))
        XCTAssertEqual(controls.reasoningBudgetTokens, 512)
    }

    func testInvalidBudgetsAreStillRefused() {
        for value in ["0", "-1", "2147483648", "9223372036854775807", "2.5", #""512""#, "true", "{}", "[]"] {
            XCTAssertThrowsError(try NemotronSuperPromptContract.controls(body: body(value)))
            XCTAssertThrowsError(try MiMoV26TemplateFix.validateRawControls(body(value)))
        }
    }

    func testPositiveBudgetConflictsWithExplicitThinkingOff() throws {
        for controls in [#""reasoning":{"enabled":false,"max_tokens":2}"#,
                         #""reasoning":{"effort":"none","max_tokens":2}"#,
                         #""enable_thinking":false,"reasoning":{"max_tokens":2}"#] {
            let data = Data("""
            {"model":"mimo-v2.6-flash-mopd","messages":[{"role":"user","content":"Hello"}],\(controls)}
            """.utf8)
            XCTAssertThrowsError(try NemotronSuperPromptContract.controls(body: data))
            let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: data)
            let template = try JSONDecoder().decode(ChatTemplateControls.self, from: data)
            XCTAssertThrowsError(try MiMoV26TemplateFix.effectiveThinkingEnabled(request: request, controls: template))
        }
    }

    /// Off must be 0.10.12 byte for byte, including which refusal a client
    /// gets: an unusable `max_tokens` beside an unknown effort is still the
    /// effort refusal (`unsupported_reasoning_control`), not a payload error.
    func testOffKeepsTodaysRefusalClassForUnusableBudgetBesideUnknownEffort() {
        for budget in ["null", #""512""#, "2.5", "true"] {
            let data = Data("""
            {"model":"mimo-v2.6-flash-mopd","messages":[{"role":"user","content":"Hello"}],
             "reasoning":{"max_tokens":\(budget),"effort":"bogus"}}
            """.utf8)
            for value in ["0", nil] as [String?] {
                if let value { setenv(flag, value, 1) } else { unsetenv(flag) }
                XCTAssertThrowsError(try MiMoV26TemplateFix.validateRawControls(data)) {
                    XCTAssertEqual(
                        $0 as? MultiModelBatchSchedulerEngineError,
                        .unsupportedReasoningEffort(.reasoningObject), "max_tokens \(budget), flag \(value ?? "unset")")
                }
            }
        }
    }

    func testOffKeepsTodaysRefusalAndAbsentFollowsTheReleaseDefault() throws {
        for value in ["0", "off", "false", "no"] {
            setenv(flag, value, 1)
            XCTAssertThrowsError(try NemotronSuperPromptContract.controls(body: body("512")))
            XCTAssertThrowsError(try MiMoV26TemplateFix.validateRawControls(body("512")))
        }
        // Unset: on for Super since 0.10.13 (`SDKFeatureDefaults`); MiMo as 0.10.12.
        unsetenv(flag)
        XCTAssertEqual(try NemotronSuperPromptContract.controls(body: body("512")).reasoningBudgetTokens, 512)
        XCTAssertThrowsError(try MiMoV26TemplateFix.validateRawControls(body("512")))
    }
}
