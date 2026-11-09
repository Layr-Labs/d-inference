import Foundation

/// The requests a slot serves, by size, as its engine enforces them. The
/// member that serves a cluster (its leader) reports the cluster's limits, for
/// every member, so the coordinator sends it only requests the cluster can
/// serve. Tokens throughout. A single Mac's slot omits it.
///
/// Mirrors Go `protocol.SlotRequestLimits` (`request_limits` on a slot):
/// `servingContextTokens` is omitted, never zero, when the owner states none.
public struct SlotRequestLimits: Codable, Sendable, Equatable {
    /// A longer prompt is refused (`prompt_too_long`).
    public var maxPromptTokens: Int
    /// A larger `max_tokens` is cut to it before the engine, which refuses one
    /// (`output_too_long`), as one Mac cuts to its window.
    public var maxOutputTokens: Int
    /// A `max_tokens` past what the prompt leaves of this is cut to fit; a
    /// prompt that leaves nothing is refused (`context_length_exceeded`).
    public var maxContextTokens: Int
    /// The longest prompt plus `max_tokens` that every member's memory gate
    /// admits now (the minimum over the ranks), re-derived while idle. A
    /// longer request is refused for capacity.
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
