import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

/// Real service serializers with scripted CPU-only generation, no model/GPU.
struct LocalOpenAIObjectCompatibilityTests {
    @Test func listedModelsHaveStableCreatedAndPreserveKnownCreation() async throws {
        let service = MLXOpenAIService(engine: ObjectCompatibilityEngine())
        let first = try await service.availableModels()
        let second = try await service.availableModels()
        let data = try JSONEncoder().encode(first)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try #require(object["data"] as? [[String: Any]])
        #expect(models[0]["created"] as? Int != nil)
        #expect(first.data[0].created == second.data[0].created)
        #expect(first.data[1].created == 77)
    }

    @Test func responsesEchoFlatToolConfigurationInCollectionAndEverySnapshot() async throws {
        let request = try JSONDecoder().decode(OpenAIResponseRequest.self, from: Data(#"{"model":"fixture","input":"hi","tools":[{"type":"function","name":"report","parameters":{"type":"object"},"strict":true}],"tool_choice":{"type":"function","name":"report"},"parallel_tool_calls":false}"#.utf8))
        let service = MLXOpenAIService(engine: ObjectCompatibilityEngine())
        let collected = try await service.createResponse(request: request)
        try assertConfiguration(JSONEncoder().encode(collected), named: true)
        var snapshotCount = 0
        for try await frame in try await service.streamResponseFrames(request: request) {
            for line in frame.split(separator: "\n") where line.hasPrefix("data: ") {
                let event = try #require(JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any])
                if let response = event["response"] as? [String: Any] {
                    try assertConfiguration(JSONSerialization.data(withJSONObject: response), named: true)
                    snapshotCount += 1
                }
            }
        }
        #expect(snapshotCount == 3)
        let plain = try await service.createResponse(request: .init(model: "fixture", input: .text("hi")))
        try assertConfiguration(JSONEncoder().encode(plain), named: false)
    }

    private func assertConfiguration(_ data: Data, named: Bool) throws {
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["parallel_tool_calls"] as? Bool == !named)
        let tools = try #require(object["tools"] as? [[String: Any]])
        #expect(tools.count == (named ? 1 : 0))
        if named {
            let tool = try #require(tools.first)
            #expect(tool["name"] as? String == "report")
            #expect(tool["type"] as? String == "function")
            #expect(tool["strict"] as? Bool == true)
            #expect(tool["function"] == nil)
            let choice = try #require(object["tool_choice"] as? [String: Any])
            #expect(choice["name"] as? String == "report")
            #expect(choice["type"] as? String == "function")
            #expect(choice["function"] == nil)
        } else { #expect(object["tool_choice"] as? String == "none") }
    }
}

private struct ObjectCompatibilityEngine: MLXServerEngine {
    func availableModels() async throws -> [MLXServerModel] { [.init(id: "fixture"), .init(id: "known", created: 77)] }
    func streamChatCompletion(request: OpenAIChatCompletionRequest) async throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.parsed(.init(content: "42", reasoningContent: nil)))
            continuation.finish()
        }
    }
    func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse { fatalError("unused") }
    func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse { fatalError("unused") }
    func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse { fatalError("unused") }
}
