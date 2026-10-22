import MLXLMCommon

/// The GLM-5.3-Flash tokenizer with thinking-off. The pinned template has no
/// thinking switch: its generation prompt always ends with an open `<think>`.
/// When `GLM5NextPromptPolicy` sets `enable_thinking` to `false`, this appends
/// `</think>`, the empty block the template writes for an assistant turn
/// without reasoning, so the answer starts as content. `<think>` and
/// `</think>` are atomic added tokens, so appending the ID equals rendering the
/// text; the platform prompt sidecar appends the same text. Every other call
/// is forwarded unchanged. The text and native-media paths both render through
/// this one instance.
struct GLM5NextThinkingTokenizer: MLXLMCommon.Tokenizer {
    enum Failure: Error, Equatable {
        case missingThinkTokens
        case generationPromptNotOpen
    }

    private let base: any MLXLMCommon.Tokenizer
    private let openID: Int
    private let closeID: Int

    init(base: any MLXLMCommon.Tokenizer) throws {
        guard let open = base.convertTokenToId("<think>"),
            let close = base.convertTokenToId("</think>"), open != close
        else { throw Failure.missingThinkTokens }
        self.base = base
        openID = open
        closeID = close
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        base.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        base.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    var bosToken: String? { base.bosToken }
    var eosToken: String? { base.eosToken }
    var unknownToken: String? { base.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try closingThinking(
            base.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext),
            additionalContext)
    }

    func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: String) throws -> [Int] {
        try base.applyChatTemplate(messages: messages, chatTemplate: chatTemplate)
    }

    func applyChatTemplate(
        messages: [[String: any Sendable]], chatTemplate: String,
        tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try closingThinking(
            base.applyChatTemplate(
                messages: messages, chatTemplate: chatTemplate, tools: tools,
                additionalContext: additionalContext),
            additionalContext)
    }

    private func closingThinking(_ tokens: [Int], _ context: [String: any Sendable]?) throws -> [Int] {
        guard context?[GLM5NextPromptPolicy.thinkingOffContextKey] as? Bool == false else {
            return tokens
        }
        // Only a generation prompt that opened the block can be closed.
        guard tokens.last == openID else { throw Failure.generationPromptNotOpen }
        return tokens + [closeID]
    }
}
