import Foundation
import Testing
@testable import ProviderCore

@Test func chatPromptFormatterPreservesOrderAndSampling() throws {
    let request = ChatCompletionRequest(
        model: "mlx-test",
        messages: [
            ChatMessage(role: "system", content: "Be terse."),
            ChatMessage(role: "user", content: "Hello"),
        ],
        temperature: 0.2,
        top_p: 0.9,
        max_tokens: 32,
        stream: true
    )

    let prompt = try ChatPromptFormatter().format(request)

    #expect(prompt.model == "mlx-test")
    #expect(prompt.messages.map(\.role) == [.system, .user])
    #expect(prompt.messages.map(\.content) == ["Be terse.", "Hello"])
    #expect(prompt.sampling.temperature == 0.2)
    #expect(prompt.sampling.topP == 0.9)
    #expect(prompt.sampling.maxTokens == 32)
    #expect(prompt.stream)
}

@Test func chatPromptFormatterRejectsUnsupportedRole() {
    let request = ChatCompletionRequest(
        model: "mlx-test",
        messages: [ChatMessage(role: "developer", content: "No")]
    )

    #expect(throws: ChatPromptFormattingError.unsupportedRole("developer")) {
        _ = try ChatPromptFormatter().format(request)
    }
}

@Test func sseFormatterBuildsDeterministicChunks() throws {
    let formatter = ChatSSEFormatter()

    let role = try formatter.roleChunk(id: "chatcmpl-test", model: "mlx-test", created: 1)
    #expect(role.formatted == #"data: {"choices":[{"delta":{"role":"assistant"},"index":0}],"created":1,"id":"chatcmpl-test","model":"mlx-test","object":"chat.completion.chunk"}"# + "\n\n")

    let usage = InferenceUsage(promptTokens: 3, completionTokens: 2)
    let finish = try formatter.finishChunk(
        id: "chatcmpl-test",
        model: "mlx-test",
        created: 1,
        reason: .length,
        usage: usage
    )
    #expect(finish.formatted.contains(#""finish_reason":"length""#))
    #expect(finish.formatted.contains(#""prompt_tokens":3"#))
    #expect(finish.formatted.contains(#""completion_tokens":2"#))
    #expect(SSEChunk.done.formatted == "data: [DONE]\n\n")
}

@Test func usageAccumulatorTracksAndBridgesUsage() {
    var usage = UsageAccumulator(promptTokens: -10)
    usage.setPromptTokens(8)
    usage.recordCompletionChunk()
    usage.recordCompletionChunk(tokenCount: 4)
    usage.recordCompletionChunk(tokenCount: -10)

    let snapshot = usage.snapshot
    #expect(snapshot.promptTokens == 8)
    #expect(snapshot.completionTokens == 5)
    #expect(snapshot.totalTokens == 13)
    #expect(snapshot.openAIChunkUsage.total_tokens == 13)
    #expect(snapshot.protocolUsageInfo.promptTokens == 8)
    #expect(snapshot.protocolUsageInfo.completionTokens == 5)
}

@Test func cancellationRegistryCancelsAndRemovesToken() async {
    let registry = InferenceCancellationRegistry()
    let token = await registry.register(requestId: "req-1")

    #expect(await registry.activeRequestIds == ["req-1"])
    #expect(!token.isCancelled)
    #expect(await registry.cancel(requestId: "req-1"))
    #expect(token.isCancelled)
    #expect(await registry.activeRequestIds.isEmpty)
    #expect(await !registry.cancel(requestId: "req-1"))
}

@Test func singleRequestDriverStreamsFakeEngineOutput() async throws {
    let engine = FakeSingleRequestEngine(events: [
        .text("hel", tokenCount: 1),
        .text("lo", tokenCount: 1),
        .usage(InferenceUsage(promptTokens: 4, completionTokens: 2)),
        .finished(.stop),
    ])
    let driver = SingleRequestInferenceDriver(engine: engine)
    let request = ChatCompletionRequest(
        model: "mlx-test",
        messages: [ChatMessage(role: "user", content: "Say hello")]
    )

    var outputs: [SingleRequestInferenceOutput] = []
    for try await output in driver.stream(requestId: "chatcmpl-test", request: request, created: 1) {
        outputs.append(output)
    }

    #expect(outputs.count == 6)
    #expect(outputs.first == .sse(try ChatSSEFormatter().roleChunk(id: "chatcmpl-test", model: "mlx-test", created: 1)))
    #expect(outputs.contains(.sse(SSEChunk.done)))
    #expect(outputs.last == .complete(InferenceUsage(promptTokens: 4, completionTokens: 2)))
}

private struct FakeSingleRequestEngine: SingleRequestChatEngine {
    let events: [SingleRequestGenerationEvent]

    func generate(
        prompt: FormattedChatPrompt,
        cancellation: InferenceCancellationToken
    ) -> AsyncThrowingStream<SingleRequestGenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                if cancellation.isCancelled {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}
