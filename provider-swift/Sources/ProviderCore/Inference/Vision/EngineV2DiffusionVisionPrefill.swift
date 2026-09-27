import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXVLM

extension EngineV2VisionPrefill {
    /// Native block-model media preparation through the same authenticated
    /// ingest, pixel caps, memory reservation and MLX-fault boundary as other
    /// providers. No autoregressive wrapper or separate generation fallback.
    static func prepareDiffusion(container: DiffusionGemmaContainer,
        request: OpenAIChatCompletionRequest, templateControls: ChatTemplateControls) async throws -> PreparedSubmission
    {
        let input = try await prepareDiffusionUserInput(request: request, templateControls: templateControls)
        let limits = VisionTowerBudget.liveLimits
        return try await container.perform(nonSendable: input) { context, input in
            guard let processor = context.processor, let geometry = context.model.visionAttentionGeometry else {
                throw EngineV2VisionPrefillError.unsupportedMedia("native diffusion artifact has no image processor/tower")
            }
            do {
                return try await MLX.withError { (errors: MLX.ErrorBox) in
                    let prepared: DiffusionGemmaMediaInput
                    do {
                        prepared = try await processor.prepare(input: input,
                            afterEvaluation: { try Self.throwIfMLXFaulted(errors) })
                    } catch let error as DiffusionGemmaModelError {
                        throw EngineV2VisionPrefillError.unsupportedMedia(error.localizedDescription)
                    }
                    guard !prepared.frames.isEmpty else { throw EngineV2VisionPrefillError.noProcessedMedia }
                    for (index, frame) in prepared.frames.enumerated() {
                        let grid = THW(1, frame.pixels.dim(2) / geometry.patchSize,
                            frame.pixels.dim(3) / geometry.patchSize)
                        if case .reject(let detail) = VisionTowerBudget.admit(grids: [grid],
                            subject: "native visual frame \(index)", limits: limits.withHeadFactor(geometry.attentionHeadFactor))
                        {
                            throw EngineV2VisionPrefillError.towerBudgetExceeded(detail)
                        }
                    }
                    guard let media = try context.model.prepareVision(prepared,
                        afterEvaluation: { try Self.throwIfMLXFaulted(errors) })
                    else { throw EngineV2VisionPrefillError.noProcessedMedia }
                    let features = try media.embeddings()
                    try Self.throwIfMLXFaulted(errors)
                    try Task.checkCancellation()
                    return PreparedSubmission(promptTokens: prepared.tokens.map(Int.init), spans: media.spans,
                        embeddings: features, spanKinds: prepared.frames.map { $0.kind == .image ? .image : .video },
                        mediaKind: Self.mediaKind(of: request))
                }
            } catch let error as MLX.MLXError { throw Self.visionPrefillError(for: error) }
        }
    }

    /// Preserve the same native input-format normalization as text without
    /// moving decoded assets or opting into an autoregressive tool grammar.
    static func prepareDiffusionUserInput(request: OpenAIChatCompletionRequest,
        templateControls: ChatTemplateControls) async throws -> UserInput {
        try DiffusionGemmaReasoningControl.validate(request: request, controls: templateControls,
            modelType: "diffusion_gemma")
        for message in request.messages where message.role != .user && message.role != .tool {
            if case .parts(let parts) = message.content, parts.contains(where: { part in
                switch part { case .imageURL, .videoURL: true; default: false }
            }) {
                // Only native user and tool-result media are supported. Keep
                // system/assistant placement fail-closed before decoding.
                throw EngineV2VisionPrefillError.unsupportedMedia(
                    "native image/video inputs require user or tool-result messages")
            }
        }
        let context = ChatTemplateFixContext(modelId: request.model, modelType: "diffusion_gemma")
        let tools = ChatTemplateFixes.normalizeTools(request.tools?.map { $0.toolSpec() }, context: context)
        try ChatTemplateFixes.validateGenericToolHistory(request.messages.map { $0.templateMessageDict() })
        var orderedRequest = request
        orderedRequest.messages = try Gemma4TurnStructure.orderTypedToolResults(request.messages)
        var input = try await MediaIngest.buildUserInput(from: orderedRequest, templateControls: templateControls,
            tools: tools, preserveTemplateFields: true, modelType: "diffusion_gemma")
        guard case .messages(let messages) = input.prompt else {
            throw EngineV2VisionPrefillError.unsupportedMedia("native media requires prepared messages")
        }
        // UserInput's messages setter preserves its separately owned images and
        // video resources; only text/tool-history dictionaries are normalized.
        input.prompt = .messages(try ChatTemplateFixes.normalizeMessages(messages, context: context))
        return input
    }
}
