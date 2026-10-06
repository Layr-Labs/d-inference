import Foundation
import MLXLMServer
import Testing
@testable import ProviderCore

struct MediaToolMetadataTests {
    @Test(arguments: ["qwen4_exp", "prism_hadamard_qwen35", "diffusion_gemma", "qwen3_5"])
    func nativeMediaKeepsNonNemotronToolMetadataPolicy(modelType: String) async throws {
        for strict in [true, false] {
            let body: [String: Any] = ["model": "fixture", "messages": [["role": "user", "content": "describe"]],
                "tools": [["type": "function", "function": ["name": "describe", "strict": strict,
                    "parameters": ["type": "object", "properties": ["strict": ["type": "boolean"]],
                        "additionalProperties": false]]]]]
            let request = try ProviderLoop.decodeOpenAIRequest(JSONSerialization.data(withJSONObject: body))
            let input = try await MediaIngest.buildUserInput(from: request,
                tools: request.tools?.map { $0.toolSpec() }, preserveTemplateFields: true,
                modelType: modelType)
            let function = try #require(input.tools?.first?["function"] as? [String: any Sendable])
            #expect(function["strict"] == nil)
            let parameters = try #require(function["parameters"] as? [String: any Sendable])
            #expect(parameters["additionalProperties"] as? Bool == false)
            let properties = try #require(parameters["properties"] as? [String: any Sendable])
            #expect((properties["strict"] as? [String: any Sendable])?["type"] as? String == "boolean")
        }
    }

    @Test func absentMediaToolsStayAbsent() async throws {
        let request = OpenAIChatCompletionRequest(model: "fixture", messages: [])
        let input = try await MediaIngest.buildUserInput(from: request, modelType: "qwen4_exp")
        #expect(input.tools == nil)
    }
}
