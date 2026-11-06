import Foundation

/// The requests a slot serves, by size, as its engine enforces them: a cluster
/// pair leader's slot reports its pair's limits so the coordinator sends it
/// only requests it can serve. Tokens throughout. A solo slot omits it.
///
/// Mirrors Go `protocol.SlotRequestLimits` (`request_limits` on a slot):
/// `servingContextTokens` is omitted when no rank derives one, never zero.
public struct SlotRequestLimits: Codable, Sendable, Equatable {
    /// A longer prompt is refused (`prompt_too_long`).
    public var maxPromptTokens: Int
    /// A larger `max_tokens` is refused (`output_too_long`).
    public var maxOutputTokens: Int
    /// Prompt plus `max_tokens` above this is refused (`context_too_long`).
    public var maxContextTokens: Int
    /// The longest prompt plus `max_tokens` every rank's memory gate admits
    /// now, re-derived while idle. A longer request is refused for capacity.
    public var servingContextTokens: Int?

    public init(maxPromptTokens: Int, maxOutputTokens: Int, maxContextTokens: Int, servingContextTokens: Int? = nil) {
        self.maxPromptTokens = maxPromptTokens
        self.maxOutputTokens = maxOutputTokens
        self.maxContextTokens = maxContextTokens
        self.servingContextTokens = servingContextTokens
    }

    enum CodingKeys: String, CodingKey {
        case maxPromptTokens = "max_prompt_tokens"
        case maxOutputTokens = "max_output_tokens"
        case maxContextTokens = "max_context_tokens"
        case servingContextTokens = "serving_context_tokens"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maxPromptTokens, forKey: .maxPromptTokens)
        try container.encode(maxOutputTokens, forKey: .maxOutputTokens)
        try container.encode(maxContextTokens, forKey: .maxContextTokens)
        try container.encodeIfPresent(servingContextTokens, forKey: .servingContextTokens)
    }
}
