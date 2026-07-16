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
/// Used by ProviderLoop and LocalMLXModelLoader.

import Foundation
import MLXLMCommon
import ProviderCoreFoundation
import Tokenizers

public struct LocalTokenizerLoader: TokenizerLoader, Sendable {
    public init() {}

    public func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        let templateURL = directory.appendingPathComponent("chat_template.jinja")
        let chatTemplate: String?
        if FileManager.default.fileExists(atPath: templateURL.path) {
            chatTemplate = try String(contentsOf: templateURL, encoding: .utf8)
        } else {
            chatTemplate = nil
        }
        return LocalTokenizerBridge(upstream, chatTemplate: chatTemplate)
    }
}

/// Adapter that satisfies `MLXLMCommon.Tokenizer` by forwarding to the
/// `swift-transformers` Tokenizer. The underlying type is a class instance
/// from a third-party library that doesn't conform to `Sendable`; we wrap
/// it as `@unchecked Sendable` because every concrete tokenizer in the
/// library is internally thread-safe (read-only after construction).
private struct LocalTokenizerBridge: @unchecked Sendable, MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer
    private let chatTemplate: String?

    init(_ upstream: any Tokenizers.Tokenizer, chatTemplate: String?) {
        self.upstream = upstream
        self.chatTemplate = chatTemplate.map(normalizeSwiftJinjaTemplate)
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
            if let chatTemplate {
                return try upstream.applyChatTemplate(
                    messages: messages,
                    chatTemplate: .literal(chatTemplate),
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
