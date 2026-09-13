import Foundation
import Testing
@testable import ProviderCore

@Suite("Cache prompt thinking parity")
struct CachePromptParityTests {
    @Test("sidecar and provider share required-tool thinking precedence across catalog aliases")
    func forcedToolThinkingVectors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("fixtures/prompt-contract/v1/forced_tool_thinking_vectors.json")
        let cases = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        #expect(cases.count == 18)
        for fixture in cases {
            let body = try JSONSerialization.data(withJSONObject: #require(fixture["request"]))
            let request = try ProviderLoop.decodeOpenAIRequest(body)
            let prepared = try ToolChoicePromptPolicy.prepare(request)
            let context = MultiModelBatchSchedulerEngine.templateAdditionalContext(
                for: request, controls: ProviderLoop.extractChatTemplateControls(from: body),
                modelType: fixture["model_type"] as? String,
                requiresToolCall: prepared.requiresToolCall)
            #expect(context?["enable_thinking"] as? Bool == fixture["enable_thinking"] as? Bool)
            #expect(context?["preserve_thinking"] as? Bool == true)
        }
    }
}
