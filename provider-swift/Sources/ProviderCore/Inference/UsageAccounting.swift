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

/// Usage state accumulated while relaying an upstream streaming response.
///
/// A normal stream finishes with an upstream usage frame. A coordinator cancel
/// usually stops before that final frame arrives, so the provider must settle
/// from the output it already emitted. This helper keeps that policy small and
/// testable: no visible output means refund; visible output means send an
/// `inference_complete` terminal using reported usage when available, otherwise
/// conservative token floors.
struct StreamedGenerationUsage: Equatable, Sendable {
    var promptTokens: Int
    var completionTokens: Int
    var reasoningTokens: Int
    var contentFrameCount: Int
    var deliveredCompletionTokenFloor: Int
    var hasVisibleOutput: Bool

    init(
        promptTokens: Int,
        completionTokens: Int,
        reasoningTokens: Int = 0,
        contentFrameCount: Int,
        deliveredCompletionTokenFloor: Int = 0,
        hasVisibleOutput: Bool
    ) {
        self.promptTokens = max(0, promptTokens)
        self.completionTokens = max(0, completionTokens)
        self.reasoningTokens = max(0, reasoningTokens)
        self.contentFrameCount = max(0, contentFrameCount)
        self.deliveredCompletionTokenFloor = max(0, deliveredCompletionTokenFloor)
        self.hasVisibleOutput = hasVisibleOutput
    }

    func cancelledTerminal(promptTokenFloor: @autoclosure () -> Int) -> CancelledGenerationTerminal {
        guard let usage = cancelledUsageInfo(promptTokenFloor: promptTokenFloor()) else {
            return .refund
        }
        return .complete(usage)
    }

    func cancelledUsageInfo(promptTokenFloor: @autoclosure () -> Int) -> UsageInfo? {
        guard hasVisibleOutput else { return nil }
        let completionFloor = max(deliveredCompletionTokenFloor, contentFrameCount)
        let settledCompletionTokens = completionTokens > 0 ? completionTokens : completionFloor
        guard settledCompletionTokens > 0 else { return nil }
        let settledPromptTokens = promptTokens > 0 ? promptTokens : max(0, promptTokenFloor())
        return usageInfo(promptTokens: settledPromptTokens, completionTokens: settledCompletionTokens)
    }

    private func usageInfo(promptTokens: Int, completionTokens: Int) -> UsageInfo {
        let completions = max(0, completionTokens)
        return UsageInfo(
            promptTokens: UInt64(max(0, promptTokens)),
            completionTokens: UInt64(completions),
            reasoningTokens: UInt64(min(max(0, reasoningTokens), completions))
        )
    }
}

enum CancelledGenerationTerminal: Equatable, Sendable {
    case refund
    case complete(UsageInfo)
}
