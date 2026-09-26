import CoreImage
import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("DiffusionGemma media prompt normalization")
struct DiffusionGemmaMediaNormalizationTests {
    @Test func toolsAndHistoryNormalizeWithoutLosingDecodedMedia() async throws {
        let image = CIImage(color: .red).cropped(to: .init(x: 0, y: 0, width: 8, height: 8))
        let png = try #require(CIContext().pngRepresentation(of: image, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        let body: [String: Any] = ["model": "native-diffusion", "messages": [
            ["role": "user", "content": [["type": "image_url", "image_url": ["url": "data:image/png;base64," + png.base64EncodedString()]],
                ["type": "text", "text": "Use the weather result and describe this image."]]],
            ["role": "assistant", "content": "", "tool_calls": [["id": "weather-1", "type": "function",
                "function": ["name": "weather", "arguments": "{\"city\":\"Paris\"}"]]]],
            ["role": "tool", "tool_call_id": "weather-1", "content": "sunny"]],
            "tools": [["type": "function", "function": ["name": "weather", "parameters": [
                "properties": ["city": ["description": "City name"]], "required": ["city"]]]]]]
        let request = try ProviderLoop.decodeOpenAIRequest(JSONSerialization.data(withJSONObject: body))
        let input = try await EngineV2VisionPrefill.prepareDiffusionUserInput(request: request, templateControls: .init())
        #expect(input.images.count == 1 && input.videos.isEmpty)
        guard case .messages(let messages) = input.prompt else { Issue.record("Lost structured messages"); return }
        let prompt = String(describing: messages)
        #expect(prompt.contains("sunny") && prompt.contains("Paris") && !prompt.contains("base64"))
        let tool = try #require(input.tools?.first)
        let function = try #require(tool["function"] as? [String: any Sendable])
        let parameters = try #require(function["parameters"] as? [String: any Sendable])
        #expect(parameters["type"] is String)
        let properties = try #require(parameters["properties"] as? [String: any Sendable])
        let city = try #require(properties["city"] as? [String: any Sendable])
        #expect(city["type"] is String)
    }

    @Test func unsupportedMediaRolesRefuseBeforeDecodingInsteadOfDroppingAssets() async throws {
        for role in ["assistant", "system"] {
            let body: [String: Any] = ["model": "native-diffusion", "messages": [["role": role,
                "content": [["type": "image_url", "image_url": ["url": "data:image/png;base64,invalid"]]]]]]
            let request = try ProviderLoop.decodeOpenAIRequest(JSONSerialization.data(withJSONObject: body))
            do {
                _ = try await EngineV2VisionPrefill.prepareDiffusionUserInput(request: request, templateControls: .init())
                Issue.record("Unsupported role media was not rejected")
            } catch EngineV2VisionPrefillError.unsupportedMedia(let message) {
                #expect(message == "native image/video inputs require user or tool-result messages")
            }
        }
    }

    @Test func orphanToolMediaRefusesHistoryBeforeDecoding() async throws {
        let body: [String: Any] = ["model": "native-diffusion", "messages": [
            ["role": "tool", "tool_call_id": "orphan", "content": [
                ["type": "image_url", "image_url": ["url": "data:image/png;base64,invalid"]]]]]]
        let request = try ProviderLoop.decodeOpenAIRequest(JSONSerialization.data(withJSONObject: body))
        do {
            _ = try await EngineV2VisionPrefill.prepareDiffusionUserInput(request: request, templateControls: .init())
            Issue.record("Orphan media result was accepted")
        } catch MultiModelBatchSchedulerEngineError.invalidToolPayload(let message) {
            #expect(message == "tool message has no preceding assistant tool_calls")
        }
    }
}
