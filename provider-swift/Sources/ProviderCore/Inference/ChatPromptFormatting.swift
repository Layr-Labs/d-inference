import Foundation

public enum ChatPromptFormattingError: Error, Equatable, Sendable {
    case emptyMessages
    case unsupportedRole(String)
    case emptyContent(role: String)
}

public enum ChatPromptRole: String, Codable, CaseIterable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public struct FormattedChatMessage: Equatable, Sendable {
    public let role: ChatPromptRole
    public let content: String

    public init(role: ChatPromptRole, content: String) {
        self.role = role
        self.content = content
    }

    public var rawMessage: [String: any Sendable] {
        ["role": role.rawValue, "content": content]
    }
}

public struct ChatSamplingParameters: Equatable, Sendable {
    public let maxTokens: Int?
    public let temperature: Float?
    public let topP: Float?
    public let topK: Int?
    public let repetitionPenalty: Float?
    public let presencePenalty: Float?
    public let frequencyPenalty: Float?

    public init(
        maxTokens: Int? = nil,
        temperature: Float? = nil,
        topP: Float? = nil,
        topK: Int? = nil,
        repetitionPenalty: Float? = nil,
        presencePenalty: Float? = nil,
        frequencyPenalty: Float? = nil
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repetitionPenalty = repetitionPenalty
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
    }
}

public struct FormattedChatPrompt: Equatable, Sendable {
    public let model: String
    public let messages: [FormattedChatMessage]
    public let sampling: ChatSamplingParameters
    public let stream: Bool

    public init(
        model: String,
        messages: [FormattedChatMessage],
        sampling: ChatSamplingParameters,
        stream: Bool
    ) {
        self.model = model
        self.messages = messages
        self.sampling = sampling
        self.stream = stream
    }

    public var rawMessages: [[String: any Sendable]] {
        messages.map(\.rawMessage)
    }
}

public struct ChatPromptFormatter: Sendable {
    public init() {}

    public func format(_ request: ChatCompletionRequest) throws -> FormattedChatPrompt {
        guard !request.messages.isEmpty else {
            throw ChatPromptFormattingError.emptyMessages
        }

        let messages = try request.messages.map { message in
            guard let role = ChatPromptRole(rawValue: message.role) else {
                throw ChatPromptFormattingError.unsupportedRole(message.role)
            }
            guard !message.content.isEmpty else {
                throw ChatPromptFormattingError.emptyContent(role: message.role)
            }
            return FormattedChatMessage(role: role, content: message.content)
        }

        return FormattedChatPrompt(
            model: request.model,
            messages: messages,
            sampling: ChatSamplingParameters(
                maxTokens: request.max_tokens,
                temperature: request.temperature,
                topP: request.top_p,
                topK: request.top_k,
                repetitionPenalty: request.repetition_penalty,
                presencePenalty: request.presence_penalty,
                frequencyPenalty: request.frequency_penalty
            ),
            stream: request.stream ?? true
        )
    }
}
