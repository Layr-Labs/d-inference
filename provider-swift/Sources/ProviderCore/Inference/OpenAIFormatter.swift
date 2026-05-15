import Foundation
import MLXLMCommon

public struct OpenAIFormatter: Sendable {
    private let encoder: JSONEncoder

    public init() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
    }

    public func makeCompletionID() -> String {
        "chatcmpl-\(UUID().uuidString.prefix(12).lowercased())"
    }

    public func roleChunk(
        id: String,
        model: String,
        created: Int
    ) -> SSEChunk {
        let chunk = ChatCompletionChunk(
            id: id,
            created: created,
            model: model,
            choices: [
                ChunkChoice(
                    index: 0,
                    delta: ChunkDelta(role: "assistant"),
                    finish_reason: nil
                )
            ]
        )
        return encodeChunk(chunk)
    }

    public func contentChunk(
        id: String,
        model: String,
        created: Int,
        text: String
    ) -> SSEChunk {
        let chunk = ChatCompletionChunk(
            id: id,
            created: created,
            model: model,
            choices: [
                ChunkChoice(
                    index: 0,
                    delta: ChunkDelta(content: text),
                    finish_reason: nil
                )
            ]
        )
        return encodeChunk(chunk)
    }

    public func stopChunk(
        id: String,
        model: String,
        created: Int,
        finishReason: String,
        usage: ChunkUsage?
    ) -> SSEChunk {
        let chunk = ChatCompletionChunk(
            id: id,
            created: created,
            model: model,
            choices: [
                ChunkChoice(
                    index: 0,
                    delta: ChunkDelta(),
                    finish_reason: finishReason
                )
            ],
            usage: usage
        )
        return encodeChunk(chunk)
    }

    public func nonStreamingResponse(
        id: String,
        model: String,
        created: Int,
        content: String,
        finishReason: String,
        usage: ChunkUsage
    ) -> ChatCompletionResponse {
        ChatCompletionResponse(
            id: id,
            created: created,
            model: model,
            choices: [
                ResponseChoice(
                    index: 0,
                    message: ResponseMessage(content: content),
                    finish_reason: finishReason
                )
            ],
            usage: usage
        )
    }

    public func encodeResponse(_ response: ChatCompletionResponse) -> Data? {
        try? encoder.encode(response)
    }

    func finishReasonString(_ reason: GenerateStopReason) -> String {
        switch reason {
        case .stop: "stop"
        case .length: "length"
        case .cancelled: "stop"
        }
    }

    private func encodeChunk(_ chunk: ChatCompletionChunk) -> SSEChunk {
        guard let data = try? encoder.encode(chunk),
              let json = String(data: data, encoding: .utf8)
        else {
            return SSEChunk(data: "{}")
        }
        return SSEChunk(data: json)
    }
}
