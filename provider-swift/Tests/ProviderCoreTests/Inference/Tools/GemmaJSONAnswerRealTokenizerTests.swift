import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Run against a local Gemma 4 snapshot (tokenizer and template files only; no
/// weights are read): `DARKBLOOM_TEST_GEMMA_TOKENIZER_DIR=<snapshot>`.
@Suite("Gemma JSON answer real tokenizer",
       .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GEMMA_TOKENIZER_DIR"] != nil))
struct GemmaJSONAnswerRealTokenizerTests {
    @Test func theShippedTokenizerMatchesThePinnedContract() async throws {
        let directory = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GEMMA_TOKENIZER_DIR"]))
        let tokenizer = try await LocalTokenizerLoader(environment: [:]).load(from: directory)
        #expect(TokenizerHandle.serving(tokenizer, modelType: "gemma4", modelDirectory: directory)
            .toolConstraintContractVerified)
        let clock = ContinuousClock()
        let started = clock.now
        let vocabulary = try GemmaAnswerPieces.vocabulary(tokenizer: tokenizer, stopTokenIDs: [1, 50, 106])
        let elapsed = clock.now - started

        // Every piece is exactly what the decoder writes for that id alone
        // (byte-fallback ids decode as a run, so they are checked below). The
        // provider's loader turns swift-transformers' clean-up off for Gemma,
        // so a space before punctuation survives.
        var mismatches: [Int] = []
        for id in vocabulary.pieceTokenIDs where vocabulary.pieces[id].count > 1 || vocabulary.pieces[id][0] < 0x80 {
            if Array(tokenizer.decode(tokenIds: [id], skipSpecialTokens: false).utf8) != vocabulary.pieces[id] {
                mismatches.append(id)
            }
        }
        #expect(mismatches.isEmpty, "first mismatches: \(mismatches.prefix(8))")
        #expect(tokenizer.decode(tokenIds: tokenizer.encode(text: "a , b .", addSpecialTokens: false),
                                 skipSpecialTokens: false) == "a , b .")
        // JSON's ASCII has a piece of its own, so ASCII byte fallback is never needed.
        let singles = Set(vocabulary.pieceTokenIDs.filter { vocabulary.pieces[$0].count == 1 }
            .map { vocabulary.pieces[$0][0] })
        for byte in [UInt8(0x0A)] + Array(0x20...0x7E) { #expect(singles.contains(byte), "byte \(byte)") }
        // A non-ASCII byte run decodes as UTF-8.
        let fallback = { (byte: UInt8) in tokenizer.convertTokenToId(String(format: "<0x%02X>", byte))! }
        #expect(tokenizer.decode(tokenIds: [fallback(0xC3), fallback(0xA9)], skipSpecialTokens: false) == "é")

        // The rendered prompts end where the constraint expects.
        for (thinking, phase) in [(false, GemmaJSONAnswerBoundary.Phase.answer), (true, .opening)] {
            let tokens = try tokenizer.applyChatTemplate(messages: [["role": "user", "content": "Extract the name."]],
                tools: nil, additionalContext: ["enable_thinking": thinking])
            let tail = tokenizer.decode(tokenIds: Array(tokens.suffix(ReasoningPromptProbe.tailTokenCount)),
                skipSpecialTokens: false)
            #expect(GemmaJSONAnswerPolicy.initialPhase(promptTail: tail) == phase)
        }

        // Real tokenizations of answers walk through, decode to themselves, and may end.
        let format = try #require(GemmaJSONAnswerPolicy.answerFormat(.jsonObject())).format
        let answerVocabulary = GemmaAnswerVocabulary(vocabulary)
        #expect(answerVocabulary.leadingWhitespace < GemmaJSONAnswerBoundary.maximumWhitespaceRun)
        let answers = [
            (GemmaJSONAnswerBoundary.Phase.answer,
             "{\"name\": \"Ada Lovelace\", \"born\": 1815, \"tags\": [\"é\", \"数学\", null],\n  \"ok\": true}"),
            (.opening, "<|channel>thought\nThe user wants {json}.<channel|>{\"a\": {\"b\": [1.5e-3, \"x y\"]}}"),
        ]
        for (phase, text) in answers {
            let constraint = try GemmaJSONAnswerConstraint(format: format, vocabulary: answerVocabulary,
                initialPhase: phase, maxTokens: 512)
            let tokens = tokenizer.encode(text: text, addSpecialTokens: false)
            #expect(tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false) == text)
            var state = constraint.initialState
            for token in tokens {
                #expect(constraint.allowedTokenIDs(state: state, remainingTokens: 512).contains(token), "token \(token)")
                state = try #require(constraint.nextState(state: state, tokenID: token), "token \(token)")
            }
            #expect(constraint.nextState(state: state, tokenID: 106) == -1)
        }
        print("gemma-json-answer-vocabulary-build: \(elapsed); longest leading whitespace "
            + "\(answerVocabulary.leadingWhitespace) bytes")
    }
}
