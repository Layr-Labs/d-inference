/// LocalTokenizerLoader -- bridges `swift-transformers`'s `AutoTokenizer`
/// to `mlx-swift-lm`'s `MLXLMCommon.Tokenizer` protocol.
///
/// This mirrors the bridge that mlx-swift-lm's `#adaptHuggingFaceTokenizer`
/// macro expands to, but done by hand because we load tokenizers from a
/// local on-disk cache rather than the Hugging Face Hub. Keeping the
/// bridge in pure Swift lets us avoid pulling in MLXHuggingFace
/// (and its BoringSSL/NIO/Jinja transitive closure) just for the
/// `from(modelFolder:)` entrypoint we already have.
///
/// Used by `ProviderLoop.loadModelContainer`, `BatchScheduler.loadModel`,
/// and `LocalMLXModelLoader`.

import Foundation
import MLXLMCommon
import ProviderCoreFoundation
import Tokenizers

public struct LocalTokenizerLoader: TokenizerLoader, Sendable {
    public init() {}

    public func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        // DAR-329: if the snapshot ships a known-broken `chat_template.jinja`
        // (e.g. the outdated Gemma 4 tool template), render with the corrected
        // upstream revision instead. Non-mutating — the on-disk file is left
        // untouched so the model's attestation/integrity hash still matches the
        // registry manifest; the corrected template is injected only at render
        // time via swift-transformers' `.literal` chat-template argument.
        let templateOverride = ChatTemplateOverride.correctedTemplate(forSnapshotDir: directory)
        return LocalTokenizerBridge(upstream, chatTemplateOverride: templateOverride)
    }
}

/// Adapter that satisfies `MLXLMCommon.Tokenizer` by forwarding to the
/// `swift-transformers` Tokenizer. The underlying type is a class instance
/// from a third-party library that doesn't conform to `Sendable`; we wrap
/// it as `@unchecked Sendable` because every concrete tokenizer in the
/// library is internally thread-safe (read-only after construction).
private struct LocalTokenizerBridge: @unchecked Sendable, MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer
    /// When set, the chat template the baked tokenizer config would use is
    /// replaced at render time by this corrected template string (DAR-329).
    /// `nil` for every model whose on-disk template is not a known-broken
    /// revision — those keep the exact baked-template path unchanged.
    private let chatTemplateOverride: String?

    init(_ upstream: any Tokenizers.Tokenizer, chatTemplateOverride: String? = nil) {
        self.upstream = upstream
        self.chatTemplateOverride = chatTemplateOverride
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            if let chatTemplateOverride {
                // Render with the corrected template (same messages/tools/
                // special-token context as the baked path — swift-transformers
                // injects those regardless of where the template string comes
                // from), so output matches a registry republish of the fix.
                return try upstream.applyChatTemplate(
                    messages: messages,
                    chatTemplate: .literal(chatTemplateOverride),
                    addGenerationPrompt: true,
                    truncation: false,
                    maxLength: nil,
                    tools: tools,
                    additionalContext: additionalContext
                )
            }
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
