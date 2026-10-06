import CoreImage
import Foundation
import MLXLMCommon
import MLXLMServer
import MLXVLM
import Testing

@testable import ProviderCore

@Suite("Diffusion tool-result media ownership")
struct DiffusionToolResultMediaTests {
    private func imageURL(_ color: CIColor) throws -> String {
        let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let data = try #require(context.pngRepresentation(of: image, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        return "data:image/png;base64," + data.base64EncodedString()
    }

    private func request(reverse: Bool = false) throws -> OpenAIChatCompletionRequest {
        let red = try imageURL(.red), blue = try imageURL(.blue)
        let resultA: [String: Any] = ["role": "tool", "tool_call_id": "actual-a", "content": [
            ["type": "text", "text": "A"], ["type": "image_url", "image_url": ["url": red]]]]
        let resultB: [String: Any] = ["role": "tool", "tool_call_id": "actual-b", "content": [
            ["type": "image_url", "image_url": ["url": blue]], ["type": "text", "text": "B"]]]
        let calls = ["actual-a", "actual-b"].map { id in
            ["id": id, "type": "function", "function": ["name": "get_image", "arguments": "{}"]] as [String: Any]
        }
        let history: [[String: Any]] = [["role": "user", "content": "Fetch two pictures"],
            ["role": "assistant", "content": "", "tool_calls": calls]]
            + (reverse ? [resultB, resultA] : [resultA, resultB])
            + [["role": "user", "content": "Describe the pictures."]]
        let body: [String: Any] = ["model": "native-diffusion", "messages": history,
            "reasoning": ["enabled": false], "tool_choice": "none"]
        return try JSONDecoder().decode(OpenAIChatCompletionRequest.self,
            from: JSONSerialization.data(withJSONObject: body))
    }

    private func color(_ image: UserInput.Image) throws -> [UInt8] {
        guard case .ciImage(let image) = image else { throw CocoaError(.coderInvalidValue) }
        var rgba = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.useSoftwareRenderer: true]).render(image, toBitmap: &rgba,
            rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return rgba
    }

    @Test func toolAssetsAndPlaceholdersFollowTheActualCallOrder() async throws {
        for reverse in [false, true] {
            let input = try await EngineV2VisionPrefill.prepareDiffusionUserInput(
                request: request(reverse: reverse), templateControls: .init())
            try #require(input.images.count == 2)
            #expect(try color(input.images[0]) == [255, 0, 0, 255])
            #expect(try color(input.images[1]) == [0, 0, 255, 255])
            guard case .messages(let messages) = input.prompt else { Issue.record("messages expected"); return }
            let results = messages.filter { $0["role"] as? String == "tool" }
            #expect(results.compactMap { $0["tool_call_id"] as? String } == ["actual-a", "actual-b"])
            let content = results.compactMap { $0["content"] as? [[String: String]] }
            try #require(content.count == 2)
            #expect(content[0].map { $0["type"] } == ["text", "image"])
            #expect(content[1].map { $0["type"] } == ["image", "text"])
            #expect(!String(describing: messages).contains("data:image"))
            #expect(!String(describing: messages).contains("__darkbloom_tool_media_index"))
        }
    }

    @Test func unsupportedRolesStillFailBeforeMediaDecode() async throws {
        for role in ["system", "assistant"] {
            let body: [String: Any] = ["model": "native-diffusion", "messages": [
                ["role": role, "content": [["type": "image_url", "image_url": ["url": "not-inline"]]]]]]
            let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self,
                from: JSONSerialization.data(withJSONObject: body))
            do {
                _ = try await EngineV2VisionPrefill.prepareDiffusionUserInput(request: request, templateControls: .init())
                Issue.record("unsupported role accepted")
            } catch let error as EngineV2VisionPrefillError {
                guard case .unsupportedMedia = error else { Issue.record("wrong refusal class"); continue }
            }
        }
    }

    @Test func legacyIngestDoesNotAcquireTheNativeRolePolicy() async throws {
        let input = try await MediaIngest.buildUserInput(from: request(), preserveTemplateFields: true,
            modelType: "qwen4_exp")
        #expect(input.images.isEmpty)
    }
}
