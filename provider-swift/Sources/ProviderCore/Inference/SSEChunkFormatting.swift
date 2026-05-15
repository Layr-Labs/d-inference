import Foundation

public enum ChatStreamFinishReason: String, Codable, Equatable, Sendable {
    case stop
    case length
    case cancelled

    public var openAIValue: String {
        switch self {
        case .stop:
            "stop"
        case .length:
            "length"
        case .cancelled:
            "stop"
        }
    }
}

public struct ChatSSEFormatter: Sendable {
    private let outputFormatting: JSONEncoder.OutputFormatting

    public init(sortedKeys: Bool = true) {
        self.outputFormatting = sortedKeys ? [.sortedKeys] : []
    }

    public func roleChunk(id: String, model: String, created: Int) throws -> SSEChunk {
        try encode(ChatCompletionChunk(
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
        ))
    }

    public func contentChunk(
        id: String,
        model: String,
        created: Int,
        text: String
    ) throws -> SSEChunk {
        try encode(ChatCompletionChunk(
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
        ))
    }

    public func finishChunk(
        id: String,
        model: String,
        created: Int,
        reason: ChatStreamFinishReason,
        usage: InferenceUsage
    ) throws -> SSEChunk {
        try encode(ChatCompletionChunk(
            id: id,
            created: created,
            model: model,
            choices: [
                ChunkChoice(
                    index: 0,
                    delta: ChunkDelta(),
                    finish_reason: reason.openAIValue
                )
            ],
            usage: usage.openAIChunkUsage
        ))
    }

    public func encode<T: Encodable>(_ value: T) throws -> SSEChunk {
        let encoder = JSONEncoder()
        encoder.outputFormatting = outputFormatting
        let data = try encoder.encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.coderInvalidValue)
        }
        return SSEChunk(data: json)
    }
}
