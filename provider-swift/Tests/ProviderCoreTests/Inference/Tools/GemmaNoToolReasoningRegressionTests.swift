import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// ASCII bytes plus Gemma 4's control tokens: the two reasoning delimiters, a
/// tool-call marker and a role marker, each a single special token.
private struct ChannelConstraintTokenizer: MLXLMCommon.Tokenizer {
    private static let specials = [
        128: "<eos>", 1000: "<|channel>", 1001: "<channel|>", 1002: "<|tool_call>", 1003: "<start_of_turn>",
    ]

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { text.utf8.map(Int.init) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.compactMap(convertIdToToken).joined()
    }
    func convertTokenToId(_ token: String) -> Int? {
        Self.specials.first { $0.value == token }?.key
    }
    func convertIdToToken(_ id: Int) -> String? {
        if let token = Self.specials[id] { return token }
        guard (0 ..< 128).contains(id), let scalar = UnicodeScalar(id) else { return nil }
        return String(Character(scalar))
    }
    var bosToken: String? { nil }
    var eosToken: String? { "<eos>" }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [] }
}

/// `tool_choice: none` on a pinned Gemma 4 prompt contract samples under
/// `GemmaNoToolTokenConstraint`. With reasoning on, the model opens its
/// thought with `<|channel>` and closes it with `<channel|>`; a mask without
/// them left it unable to reason, and it repeated until its output cap.
@Suite("Gemma no-tool native reasoning boundaries")
struct GemmaNoToolReasoningRegressionTests {
    private static let modelID = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
    private static var hasTokenizerFixture: Bool {
        ModelScanner.resolveLocalPath(modelID: modelID) != nil
    }

    @Test(.enabled(if: Self.hasTokenizerFixture))
    func actualPinnedTokenizerKeepsNativeReasoningDelimiters() async throws {
        let directory = try #require(ModelScanner.resolveLocalPath(modelID: Self.modelID))
        #expect(Gemma4ToolConstraintContract.isVerified(modelType: "gemma4", modelDirectory: directory))
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        let eos = try #require(tokenizer.eosTokenId)
        let vocabulary = try GemmaTokenVocabulary(tokenizer: tokenizer, stopTokenIDs: [eos])
        let constraint = GemmaNoToolTokenConstraint(maxTokens: 128, vocabulary: vocabulary)
        let allowed = Set(constraint.allowedTokenIDs(state: 0, remainingTokens: 128))
        for token in ["<|channel>", "<channel|>"] {
            let id = try #require(tokenizer.convertTokenToId(token))
            #expect(allowed.contains(id), "\(token)")
            #expect(constraint.nextState(state: 0, tokenID: id) == 0, "\(token)")
        }
        let forbidden = try #require(tokenizer.convertTokenToId("<|tool_call>"))
        #expect(!allowed.contains(forbidden))
    }

    @Test func reasoningChannelsRemainAvailableButToolAndRoleMarkersDoNot() throws {
        let vocabulary = try GemmaTokenVocabulary(tokenizer: ChannelConstraintTokenizer(), stopTokenIDs: [128])
        let constraint = GemmaNoToolTokenConstraint(maxTokens: 128, vocabulary: vocabulary)
        let allowed = Set(constraint.allowedTokenIDs(state: 0, remainingTokens: 128))
        #expect(allowed.contains(1000))
        #expect(allowed.contains(1001))
        #expect(constraint.nextState(state: 0, tokenID: 1000) == 0)
        #expect(constraint.nextState(state: 0, tokenID: 1001) == 0)
        #expect(!allowed.contains(1002))
        #expect(!allowed.contains(1003))
        // The delimiters never enter the structured-tool JSON vocabulary.
        #expect(vocabulary.pieces[1000] == nil && vocabulary.pieces[1001] == nil)
        #expect(allowed.contains(128))
    }

    @Test func partialForbiddenMarkersCannotBeSplicedAcrossChannelBoundaries() throws {
        let vocabulary = try GemmaTokenVocabulary(tokenizer: ChannelConstraintTokenizer(), stopTokenIDs: [128])
        let constraint = GemmaNoToolTokenConstraint(maxTokens: 128, vocabulary: vocabulary)
        var state = constraint.initialState
        for byte in "<|tool_call".utf8 {
            state = try #require(constraint.nextState(state: state, tokenID: Int(byte)))
        }
        #expect(state != 0)
        #expect(!constraint.allowedTokenIDs(state: state, remainingTokens: 128).contains(1000))
        #expect(constraint.nextState(state: state, tokenID: 1000) == nil)
        #expect(constraint.nextState(state: state, tokenID: 1001) == nil)
        #expect(constraint.nextState(state: state, tokenID: Int(Character(">").asciiValue!)) == nil)
    }
}
