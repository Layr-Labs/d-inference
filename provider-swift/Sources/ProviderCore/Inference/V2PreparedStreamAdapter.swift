import Foundation
import MLXLMServer

public enum V2PreparedStreamAdapterError: Error, Sendable, Equatable {
    case streamAlreadyConsumed
    case requestIdentityMismatch
    case cancelled
    case unsupportedUtilityEndpoint
}

private actor V2PreparedStreamConsumption {
    private var consumed = false

    func claim() -> Bool {
        guard !consumed else { return false }
        consumed = true
        return true
    }
}

/// One-shot `MLXServerEngine` view over an already-authorized generation
/// stream. This is the boundary that lets `MLXOpenAIService` remain the sole
/// SSE/tool/reasoning/usage formatter without ever submitting inference itself.
public struct V2PreparedStreamAdapter: MLXServerEngine, Sendable {
    private let prepared: PreparedInference
    private let execution: PreparedInferenceExecution
    private let consumption = V2PreparedStreamConsumption()

    public init(
        prepared: PreparedInference,
        execution: PreparedInferenceExecution
    ) {
        self.prepared = prepared
        self.execution = execution
    }

    public func availableModels() async throws -> [MLXServerModel] {
        [MLXServerModel(id: prepared.modelID)]
    }

    public func streamChatCompletion(
        request: OpenAIChatCompletionRequest
    ) async throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        guard request.model == prepared.modelID else {
            throw V2PreparedStreamAdapterError.requestIdentityMismatch
        }
        guard await consumption.claim() else {
            throw V2PreparedStreamAdapterError.streamAlreadyConsumed
        }

        let events = execution.events
        let promptTokenFloor = prepared.facts.promptTokens
        let toolHandler = prepared.toolCallFormat.map {
            BatchedToolStreamHandler(format: $0, tools: prepared.toolSpecs)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                let startedAt = Date()
                var firstTokenAt: Date?
                var lastTokenAt: Date?
                var promptTokens = promptTokenFloor
                var completionTokens = 0
                var stopReason = "stop"
                var failure: String?

                for await event in events {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    switch event {
                    case .chunk(let text):
                        if firstTokenAt == nil { firstTokenAt = Date() }
                        lastTokenAt = Date()
                        guard !text.isEmpty else { continue }
                        if let toolHandler {
                            if let visible = toolHandler.processChunk(text), !visible.isEmpty {
                                continuation.yield(.content(visible))
                            }
                        } else {
                            continuation.yield(.content(text))
                        }
                    case .info(let prompt, let completion, _, let reason):
                        // Join actual engine usage out-of-band before a following error can
                        // terminate SSE formatting. Production's EngineV2 pump also records
                        // token deltas, while this boundary covers alternate executors that
                        // report only GenerationEvent.info.
                        await execution.usageLedger.record(
                            promptTokens: prompt,
                            finalGeneratedTokens: completion
                        )
                        promptTokens = max(promptTokenFloor, prompt)
                        completionTokens = max(0, completion)
                        if let reason { stopReason = reason }
                    case .error(let message):
                        failure = message
                    }
                }

                if let failure {
                    if failure.localizedCaseInsensitiveContains("cancel") {
                        continuation.finish(
                            throwing: V2PreparedStreamAdapterError.cancelled)
                    } else {
                        continuation.finish(
                            throwing:
                                MultiModelBatchSchedulerEngineError
                                .fromSchedulerMessage(failure)
                        )
                    }
                    return
                }

                if let toolHandler {
                    for toolCall in toolHandler.finish() {
                        continuation.yield(.toolCall(toolCall))
                    }
                }

                let endedAt = Date()
                continuation.yield(
                    .info(
                        ServerGenerationInfo(
                            promptTokens: promptTokens,
                            completionTokens: completionTokens,
                            promptTime: max(
                                0, (firstTokenAt ?? endedAt).timeIntervalSince(startedAt)),
                            generationTime: max(
                                0,
                                (lastTokenAt ?? endedAt)
                                    .timeIntervalSince(firstTokenAt ?? startedAt)),
                            stopReason: stopReason
                        )))
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse {
        throw V2PreparedStreamAdapterError.unsupportedUtilityEndpoint
    }

    public func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse {
        throw V2PreparedStreamAdapterError.unsupportedUtilityEndpoint
    }

    public func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse {
        throw V2PreparedStreamAdapterError.unsupportedUtilityEndpoint
    }
}
