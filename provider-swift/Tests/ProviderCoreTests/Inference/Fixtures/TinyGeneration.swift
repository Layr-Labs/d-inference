import Foundation
import Testing

@testable import ProviderCore

/// The result of one short generation.
struct TinyGeneration {
    var promptTokens: Int?
    var completionTokens: Int?
    var finishReason: String?
    var errors: [String] = []

    static let prompt = "Hello"
    /// Byte-level ids of `prompt`: the tokenizer maps each byte to its own id.
    static let promptTokenIDs = Array(prompt.utf8).map(Int.init)
    private static let maxTokens = 4

    private static func request(modelID: String) -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: modelID, messages: [.init(role: "user", content: prompt)],
            temperature: 0, max_tokens: maxTokens)
    }

    /// Submit the prompt to `bridge` and read the stream to its end, for at
    /// most `timeout`.
    static func run(
        bridge: EngineV2Bridge, modelID: String, timeout: Duration = .seconds(60)
    ) async -> TinyGeneration {
        let stream = await bridge.submitTokenized(
            promptTokens: promptTokenIDs, request: request(modelID: modelID),
            requestId: "tiny-\(UUID().uuidString)")
        let reader = Task { () -> TinyGeneration in
            var result = TinyGeneration()
            for await event in stream {
                switch event {
                case .chunk:
                    break  // The text is not checked: the weights are random.
                case .info(let prompt, let completion, _, let finish):
                    result.promptTokens = prompt
                    result.completionTokens = completion
                    result.finishReason = finish
                case .error(let message):
                    result.errors.append(message)
                case .terminal(let cause, let message, _, _):
                    result.errors.append("\(cause): \(message)")
                }
            }
            return result
        }
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            reader.cancel()
        }
        let result = await reader.value
        watchdog.cancel()
        return result
    }

    /// The checks every generation must pass: the whole prompt was read, at
    /// least one token came out, and the finish reason fits the token count.
    /// The exact tokens are not checked: the weights are random.
    func check(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(errors.isEmpty, "generation errors: \(errors)", sourceLocation: sourceLocation)
        #expect(promptTokens == Self.promptTokenIDs.count, sourceLocation: sourceLocation)
        let completion = completionTokens ?? 0
        #expect((1...Self.maxTokens).contains(completion),
                "completion tokens: \(completion)", sourceLocation: sourceLocation)
        switch finishReason {
        case "length":
            #expect(completion == Self.maxTokens, sourceLocation: sourceLocation)
        case "stop":
            break  // The model chose the end token before the limit.
        default:
            Issue.record("unexpected finish reason: \(String(describing: finishReason))",
                         sourceLocation: sourceLocation)
        }
    }
}
