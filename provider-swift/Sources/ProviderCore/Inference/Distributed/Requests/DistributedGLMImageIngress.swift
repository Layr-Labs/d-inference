import Foundation
import CryptoKit
import DarkbloomClusterProtocol
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXVLM

/// Host-only ingress: native GLM tool/history normalization, bounded encoded
/// PNG inspection, template expansion and causal spans. No MLX/raster objects.
struct DistributedGLMImageIngress: Sendable {
    let configuration: GLM5NextConfiguration
    let configurationSHA256: String
    init(configuration bytes: Data, expectedSHA256: String) throws {
        guard !bytes.isEmpty, bytes.count <= 32 * 1024 * 1024,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expectedSHA256 else {
            throw DistributedEngineError.invalidConfiguration("GLM media configuration differs from loaded peers")
        }
        configuration = try JSONDecoder().decode(GLM5NextConfiguration.self, from: bytes)
        configurationSHA256 = expectedSHA256
        try GLM5NextClusterImagePlan.requireConfiguration(configuration)
        guard configuration.imageTokenId == GLM5NextProcessor.imageToken,
              configuration.videoTokenId == GLM5NextProcessor.videoToken,
              configuration.imageStartTokenId == 154830, configuration.imageEndTokenId == 154831 else {
            throw DistributedEngineError.invalidConfiguration("GLM native media markers differ")
        }
    }
    func prepare(request: OpenAIChatCompletionRequest, controls: ChatTemplateControls,
                 tokenizer: any Tokenizer, maximumPromptTokens: Int,
                 maximumOutputTokens: Int) throws -> (tokens: [Int], wire: Data) {
        guard maximumOutputTokens > 0, !MediaIngest.hasVideo(request) else { throw bad("GLM video input is not qualified") }
        var textRequest = request
        for index in request.messages.indices {
            textRequest.messages[index].content = .text(request.messages[index].textContent)
        }
        let prepared = try ToolChoicePromptPolicy.prepare(textRequest, modelType: "glm5_next")
        let normalized = try GLM5NextPromptPolicy.normalizedTextInput(request: textRequest, prepared: prepared, controls: controls)
        var messages = normalized.messages
        let prefix = messages.count - request.messages.count
        guard (0...1).contains(prefix) else { throw bad("GLM prompt alignment") }
        var images: [(Data, GLM5NextClusterImagePlan.Inspection)] = []
        var remaining = ClusterStillImages.maximumEncodedBytes
        for index in request.messages.indices {
            let message = request.messages[index]
            guard case .parts(let parts) = message.content else { continue }
            var content: [[String: String]] = []
            for part in parts {
                switch part {
                case .text(let text): content.append(["type": "text", "text": text])
                case .imageURL(let uri):
                    guard message.role == .user, images.count < ClusterStillImages.maximumImages else {
                        throw bad("GLM still images require a bounded user input")
                    }
                    let header = "data:image/png;base64,"
                    guard uri.hasPrefix(header), uri.utf8.count <= header.utf8.count + (remaining + 2) / 3 * 4 else {
                        throw bad("GLM cluster still images require bounded inline PNG")
                    }
                    let data = try MediaIngest.dataFromDataURI(uri, maxMediaDecodedBytes: remaining)
                    let inspection: GLM5NextClusterImagePlan.Inspection
                    do { inspection = try GLM5NextClusterImagePlan.inspectPNG(data, configuration: configuration) }
                    catch { throw bad("GLM still-image geometry or codec exceeds the supported bound") }
                    remaining -= data.count; images.append((data, inspection))
                    content.append(["type": "image"])
                case .videoURL: throw bad("GLM video input is not qualified")
                case .inputAudio, .unsupported: throw bad("GLM cluster audio input is unsupported")
                }
            }
            messages[index + prefix]["content"] = content
        }
        guard !images.isEmpty else { throw bad("GLM image input is empty") }
        let processor = try GLM5NextProcessor(configuration: GLM5NextClusterImagePlan.processorConfiguration(configuration), tokenizer: tokenizer)
        let symbolic = try tokenizer.applyChatTemplate(messages: messages, tools: normalized.tools,
            additionalContext: normalized.additionalContext)
        let expansion = try processor.expandPrompt(symbolic, images: images.map { $0.1.resize.grid }, videos: [])
        guard expansion.tokens.count <= maximumPromptTokens,
              expansion.tokens.count <= configuration.textConfig.maxPositionEmbeddings - maximumOutputTokens,
              expansion.placements.count == images.count else { throw bad("GLM image prompt exceeds context") }
        let values = zip(images, expansion.placements).map { image, span in
            ClusterStillImages.Image(png: image.0, width: image.1.width, height: image.1.height,
                tokenOffset: span.tokenRange.lowerBound, tokenCount: span.tokenRange.count)
        }
        let media = ClusterStillImages(configurationSHA256: configurationSHA256, images: values)
        try media.validate(prompt: expansion.tokens, imageToken: configuration.imageTokenId,
            startToken: configuration.imageStartTokenId, endToken: configuration.imageEndTokenId,
            videoToken: configuration.videoTokenId)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let wire = try encoder.encode(media)
        _ = try ClusterStillImages.decodeBounded(wire)
        return (expansion.tokens, wire)
    }
    private func bad(_ detail: String) -> MultiModelBatchSchedulerEngineError { .multimodalRejected(detail) }
}
