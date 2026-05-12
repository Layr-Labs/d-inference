import Foundation

public enum SingleRequestGenerationEvent: Equatable, Sendable {
    case text(String, tokenCount: Int = 1)
    case usage(InferenceUsage)
    case finished(ChatStreamFinishReason)
}

public enum SingleRequestInferenceOutput: Equatable, Sendable {
    case sse(SSEChunk)
    case complete(InferenceUsage)

    public static func == (
        lhs: SingleRequestInferenceOutput,
        rhs: SingleRequestInferenceOutput
    ) -> Bool {
        switch (lhs, rhs) {
        case (.sse(let left), .sse(let right)):
            return left.data == right.data
        case (.complete(let left), .complete(let right)):
            return left == right
        default:
            return false
        }
    }
}

public protocol SingleRequestChatEngine: Sendable {
    func generate(
        prompt: FormattedChatPrompt,
        cancellation: InferenceCancellationToken
    ) -> AsyncThrowingStream<SingleRequestGenerationEvent, Error>
}

public struct SingleRequestInferenceDriver<Engine: SingleRequestChatEngine>: Sendable {
    private let engine: Engine
    private let promptFormatter: ChatPromptFormatter
    private let sseFormatter: ChatSSEFormatter

    public init(
        engine: Engine,
        promptFormatter: ChatPromptFormatter = ChatPromptFormatter(),
        sseFormatter: ChatSSEFormatter = ChatSSEFormatter()
    ) {
        self.engine = engine
        self.promptFormatter = promptFormatter
        self.sseFormatter = sseFormatter
    }

    public func stream(
        requestId: String,
        request: ChatCompletionRequest,
        created: Int,
        cancellation: InferenceCancellationToken = InferenceCancellationToken()
    ) -> AsyncThrowingStream<SingleRequestInferenceOutput, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prompt = try promptFormatter.format(request)
                    try cancellation.checkCancellation()

                    continuation.yield(.sse(try sseFormatter.roleChunk(
                        id: requestId,
                        model: prompt.model,
                        created: created
                    )))

                    var usage = UsageAccumulator()
                    var finishReason = ChatStreamFinishReason.stop

                    for try await event in engine.generate(prompt: prompt, cancellation: cancellation) {
                        try cancellation.checkCancellation()

                        switch event {
                        case .text(let text, let tokenCount):
                            usage.recordCompletionChunk(tokenCount: tokenCount)
                            continuation.yield(.sse(try sseFormatter.contentChunk(
                                id: requestId,
                                model: prompt.model,
                                created: created,
                                text: text
                            )))

                        case .usage(let finalUsage):
                            usage.merge(finalUsage)

                        case .finished(let reason):
                            finishReason = reason
                        }
                    }

                    try cancellation.checkCancellation()
                    let finalUsage = usage.snapshot
                    continuation.yield(.sse(try sseFormatter.finishChunk(
                        id: requestId,
                        model: prompt.model,
                        created: created,
                        reason: finishReason,
                        usage: finalUsage
                    )))
                    continuation.yield(.sse(.done))
                    continuation.yield(.complete(finalUsage))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                cancellation.cancel()
                task.cancel()
            }
        }
    }
}
