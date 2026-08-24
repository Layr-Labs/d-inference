// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

struct Qwen38ProductionCanaryFixture: @unchecked Sendable {
    let modelDirectory: URL
    let assistantDirectory: URL
    let imageURL: URL
    let videoURL: URL
    let container: ModelContainer
    let targetSizing: SlotSizingSnapshot
    let tokenizer: TokenizerHandle
    let assistantLayerCount: Int

    func removeStagedAssistant() {
        try? FileManager.default.removeItem(at: assistantDirectory)
    }

    func makeBundle(preparation: SpecDecPreparation) async throws -> ProviderEngineBundle {
        let prepared = try await EngineV2SlotFactory.prepareProductionModel(
            modelId: Qwen38ProductionCanary.targetModelID,
            isVLM: true,
            modelDirectory: modelDirectory,
            container: container,
            specDecPreparation: preparation)
        let sizing = targetSizing.replacingAuxiliaryWeightBytes(prepared.assistantBytes)
        let grant = Int(min(
            UnifiedMemoryCap.kvBudgetBytes(
                physicalBytes: ProcessInfo.processInfo.physicalMemory,
                residentWeightBytes: UInt64(max(0, sizing.weightsBytes)),
                configReserveBytes: 0),
            UInt64(Int.max)))
        do {
            return try await EngineV2SlotFactory.makeProductionBundle(
                modelId: Qwen38ProductionCanary.targetModelID,
                modelType: Qwen38ProductionCanary.modelType,
                isVLM: true,
                modelDirectory: modelDirectory,
                container: container,
                tokenizer: tokenizer,
                sizing: sizing,
                kvBytesCapacity: grant,
                maxConcurrentRequests: 2,
                kvBudget: nil,
                specDecPreparation: preparation,
                preparedModel: prepared,
                environment: [
                    "DARKBLOOM_PREFIX_CACHE": "0",
                    "DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS": "0",
                ])
        } catch {
            prepared.assistant?.release()
            MLX.Memory.clearCache()
            throw error
        }
    }

    func separateMTPPreparation() async -> SpecDecPreparation {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen38-mtp-store-\(UUID().uuidString)")
        let funnel = SpecDecArtifactFunnel(
            resolver: SpecDecResolver(storeRoot: store),
            catalog: nil)
        let preparation = await funnel.prepare(.init(
            modelId: Qwen38ProductionCanary.targetModelID,
            modelType: Qwen38ProductionCanary.modelType,
            enabled: true,
            localPath: assistantDirectory.path,
            modelDirectory: modelDirectory,
            allowDownload: false,
            environment: ["DARKBLOOM_CBV2_MTP": "1"]))
        await funnel.shutdown()
        try? FileManager.default.removeItem(at: store)
        return preparation
    }

    func service(bundle: ProviderEngineBundle) -> MLXOpenAIService {
        let entry = MultiModelBatchSchedulerEngine.ModelRegistryEntry(
            tokenizer: tokenizer,
            modelType: Qwen38ProductionCanary.modelType,
            container: container,
            isVLM: true,
            engineV2Bridge: bundle.bridge)
        let scheduler = MultiModelBatchSchedulerEngine(
            registryProvider: { [entry] in
                [Qwen38ProductionCanary.targetModelID: entry]
            },
            defaultMaxTokens: 512)
        return MLXOpenAIService(engine: scheduler)
    }

    func baseRequest(
        prompt: String,
        maxTokens: Int = 64,
        reasoning: Bool = false
    ) -> OpenAIChatCompletionRequest {
        OpenAIChatCompletionRequest(
            model: Qwen38ProductionCanary.targetModelID,
            messages: [.init(role: .user, content: .text(prompt))],
            reasoning: .init(enabled: reasoning),
            temperature: 0,
            topP: 1,
            topK: 0,
            minP: 0,
            maxTokens: maxTokens)
    }

    func checkText(using service: MLXOpenAIService) async throws {
        let response = try await service.createChatCompletion(
            request: baseRequest(prompt: "Reply exactly QWEN38_TEXT_OK and nothing else."))
        #expect(responseText(response) == "QWEN38_TEXT_OK")
        #expect(response.usage.promptTokens > 0)
        #expect(response.usage.completionTokens > 0)
    }

    func checkStreaming(using service: MLXOpenAIService) async throws {
        var request = baseRequest(prompt: "Reply exactly QWEN38_STREAM_OK and nothing else.")
        request.stream = true
        request.streamOptions = .init(includeUsage: true)
        let frames = try await service.streamChatCompletionFrames(request: request)
        var text = ""
        var sawDone = false
        var sawUsage = false
        for try await frame in frames {
            if frame == ServerSentEventEncoder.done {
                sawDone = true
                continue
            }
            guard frame.hasPrefix("data: ") else { continue }
            let json = String(frame.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = json.data(using: .utf8) else { continue }
            let chunk = try JSONDecoder().decode(OpenAIChatCompletionChunk.self, from: data)
            text += chunk.choices.first?.delta.content ?? ""
            sawUsage = sawUsage || chunk.usage != nil
        }
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "QWEN38_STREAM_OK")
        #expect(sawDone)
        #expect(sawUsage)
    }

    func checkJSON(using service: MLXOpenAIService) async throws {
        var request = baseRequest(
            prompt: #"Return exactly {"model":"qwen3.8","ok":true} and no markdown."#)
        request.responseFormat = .jsonObject()
        let response = try await service.createChatCompletion(request: request)
        let text = responseText(response)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["model"] as? String == "qwen3.8")
        #expect(object["ok"] as? Bool == true)
    }

    func checkReasoning(using service: MLXOpenAIService) async throws {
        var request = baseRequest(
            prompt: "Compute 19 * 23. Put only the number in the final answer.",
            maxTokens: 160,
            reasoning: true)
        request.reasoningParser = .qwen3
        let response = try await service.createChatCompletion(request: request)
        let message = try #require(response.choices.first?.message)
        #expect(message.reasoningContent?.isEmpty == false)
        #expect(responseText(response).contains("437"))
    }

    func checkRequiredTool(using service: MLXOpenAIService) async throws {
        let schema: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "city": .object(["type": .string("string")])
            ]),
            "required": .array([.string("city")]),
            "additionalProperties": .bool(false),
        ])
        var request = baseRequest(
            prompt: "Call get_weather exactly once for Boston. Do not write prose.",
            maxTokens: 96)
        request.tools = [.init(function: .init(
            name: "get_weather",
            description: "Get the weather for a city.",
            parameters: schema))]
        request.toolChoice = .mode(.required)
        request.toolCallParser = "qwen3_coder"
        let response = try await service.createChatCompletion(request: request)
        let calls = try #require(response.choices.first?.message.toolCalls)
        let call = try #require(calls.first)
        #expect(calls.count == 1)
        #expect(call.function.name == "get_weather")
        #expect(call.function.arguments.contains("Boston"))
    }

    func checkImage(using service: MLXOpenAIService) async throws {
        let response = try await service.createChatCompletion(
            request: mediaRequest(
                prompt: "Identify the logo in the image. Include the letters MLX in the answer.",
                parts: [.imageURL(try dataURI(imageURL, mime: "image/png"))]))
        #expect(responseText(response).localizedCaseInsensitiveContains("MLX"))
    }

    func checkMultipleImages(using service: MLXOpenAIService) async throws {
        let image = try dataURI(imageURL, mime: "image/png")
        let response = try await service.createChatCompletion(
            request: mediaRequest(
                prompt: "How many images are attached? Reply with only the number.",
                parts: [.imageURL(image), .imageURL(image)]))
        #expect(responseText(response).trimmingCharacters(in: .whitespacesAndNewlines) == "2")
    }

    func checkVideo(using service: MLXOpenAIService) async throws {
        let response = try await service.createChatCompletion(
            request: mediaRequest(
                prompt: "Describe the main test pattern in this video in a short phrase.",
                parts: [.videoURL(try dataURI(videoURL, mime: "video/quicktime"))],
                maxTokens: 96))
        let text = responseText(response)
        #expect(
            text.localizedCaseInsensitiveContains("color bar")
                || text.localizedCaseInsensitiveContains("colour bar"))
    }

    func checkMixedMedia(using service: MLXOpenAIService) async throws {
        let image = try dataURI(imageURL, mime: "image/png")
        let video = try dataURI(videoURL, mime: "video/quicktime")
        let response = try await service.createChatCompletion(
            request: mediaRequest(
                prompt: "Name the image logo and the video's test pattern. Mention MLX and color bars.",
                parts: [.imageURL(image), .videoURL(video)],
                maxTokens: 128))
        let text = responseText(response)
        #expect(text.localizedCaseInsensitiveContains("MLX"))
        #expect(
            text.localizedCaseInsensitiveContains("color bar")
                || text.localizedCaseInsensitiveContains("colour bar"))
    }

    func mediaRequest(
        prompt: String,
        parts: [OpenAIContentPart],
        maxTokens: Int = 64
    ) -> OpenAIChatCompletionRequest {
        OpenAIChatCompletionRequest(
            model: Qwen38ProductionCanary.targetModelID,
            messages: [.init(
                role: .user,
                content: .parts([.text(prompt)] + parts))],
            reasoning: .init(enabled: false),
            temperature: 0,
            topP: 1,
            topK: 0,
            minP: 0,
            maxTokens: maxTokens)
    }

    func parityRequest() -> OpenAIChatCompletionRequest {
        baseRequest(
            prompt: "Explain speculative decoding, target verification, rejection rollback, and cache safety.",
            maxTokens: Qwen38ProductionCanary.parityMaxTokens)
    }

    func tokenize(_ request: OpenAIChatCompletionRequest) throws -> [Int] {
        let prepared = try ToolChoicePromptPolicy.prepare(request)
        return try ProviderPromptContractPipeline.tokenize(
            prepared: prepared,
            request: request,
            tokenizer: tokenizer.inner,
            modelType: Qwen38ProductionCanary.modelType,
            reasoningEffort: nil)
    }

    private func responseText(_ response: OpenAIChatCompletionResponse) -> String {
        guard let content = response.choices.first?.message.content else { return "" }
        if case .text(let text) = content {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private func dataURI(_ url: URL, mime: String) throws -> String {
        "data:\(mime);base64," + (try Data(contentsOf: url)).base64EncodedString()
    }
}
