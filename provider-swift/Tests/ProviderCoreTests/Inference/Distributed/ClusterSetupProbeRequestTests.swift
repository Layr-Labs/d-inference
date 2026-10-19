import Foundation
import MLXLMServer
import Testing
@testable import ProviderCore

@Suite struct ClusterSetupProbeRequestTests {
    private func context(_ body: [String: Any]) throws -> [String: any Sendable] {
        let data = try JSONSerialization.data(withJSONObject: body)
        let request = try ProviderLoop.decodeOpenAIRequest(data, modelType: "glm5_next")
        let controls = ProviderLoop.extractChatTemplateControls(from: data)
        return try GLM5NextPromptPolicy.additionalContext(request: request, controls: controls)
    }

    @Test func ordinaryProbePassesActualGLMPromptValidation() throws {
        let body = ClusterSetupProbeRequest.body(model: "fixture-model", text: "Say hello", maxTokens: 16)
        let value = try context(body)
        #expect(value["reasoning_effort"] as? String == "max")
        #expect(body["enable_thinking"] == nil)
        #expect(body["max_tokens"] as? Int == 16)
        #expect(body["stream"] as? Bool == true)
    }

    @Test func oldWizardBinaryThinkingControlIsStillRejected() throws {
        var body = ClusterSetupProbeRequest.body(model: "fixture-model", text: "Say hello", maxTokens: 16)
        body["enable_thinking"] = false
        #expect(throws: (any Error).self) { _ = try context(body) }
    }
}
