import Foundation

public struct InferenceUsage: Codable, Equatable, Sendable {
    public let promptTokens: Int
    public let completionTokens: Int

    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = max(0, promptTokens)
        self.completionTokens = max(0, completionTokens)
    }

    public var totalTokens: Int {
        promptTokens + completionTokens
    }

    public var openAIChunkUsage: ChunkUsage {
        ChunkUsage(prompt_tokens: promptTokens, completion_tokens: completionTokens)
    }

    public var protocolUsageInfo: UsageInfo {
        UsageInfo(
            promptTokens: UInt64(promptTokens),
            completionTokens: UInt64(completionTokens)
        )
    }
}

public struct UsageAccumulator: Sendable {
    private var promptTokens: Int
    private var completionTokens: Int

    public init(promptTokens: Int = 0, completionTokens: Int = 0) {
        self.promptTokens = max(0, promptTokens)
        self.completionTokens = max(0, completionTokens)
    }

    public mutating func setPromptTokens(_ count: Int) {
        promptTokens = max(0, count)
    }

    public mutating func setCompletionTokens(_ count: Int) {
        completionTokens = max(0, count)
    }

    public mutating func recordCompletionChunk(tokenCount: Int = 1) {
        completionTokens += max(0, tokenCount)
    }

    public mutating func merge(_ usage: InferenceUsage) {
        promptTokens = usage.promptTokens
        completionTokens = usage.completionTokens
    }

    public var snapshot: InferenceUsage {
        InferenceUsage(promptTokens: promptTokens, completionTokens: completionTokens)
    }
}
