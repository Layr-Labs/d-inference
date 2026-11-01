import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Run against a local Qwen 3.5/3.6/3.8 snapshot (tokenizer and template files
/// only; no weights are read): `DARKBLOOM_TEST_QWEN_TOKENIZER_DIR=<snapshot>`.
@Suite("Qwen JSON answer real tokenizer",
       .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_QWEN_TOKENIZER_DIR"] != nil))
struct QwenJSONAnswerRealTokenizerTests {
    @Test func theShippedTokenizerMatchesThePinnedContract() async throws {
        let directory = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["DARKBLOOM_TEST_QWEN_TOKENIZER_DIR"]))
        let tokenizer = try await LocalTokenizerLoader(environment: [:]).load(from: directory)
        let clock = ContinuousClock()
        let started = clock.now
        let vocabulary = try JSONAnswerVocabulary(tokenizer: tokenizer, profile: .qwen35,
            stopTokenIDs: [248044, 248046])
        let elapsed = clock.now - started
        #expect(vocabulary.pieceTokenIDs.count == 248_046)
        // The rendered JSON prompts end where the constraint expects.
        for (thinking, phase) in [(false, JSONAnswerPhase.answer), (true, .reasoning)] {
            let tokens = try tokenizer.applyChatTemplate(messages: [["role": "user", "content": "Extract the name."]],
                tools: nil, additionalContext: ["enable_thinking": thinking])
            let tail = tokenizer.decode(tokenIds: Array(tokens.suffix(ReasoningPromptProbe.tailTokenCount)),
                skipSpecialTokens: false)
            #expect(JSONAnswerProfile.qwen35.initialPhase(promptTail: tail) == phase)
        }
        // A real tokenization of a valid answer walks through and may end.
        let answer = try JSONAnswerFormat(.jsonObject(), forbidding: JSONAnswerProfile.qwen35.contentMarkers,
            family: "Qwen")
        let constraint = try JSONAnswerConstraint(format: answer, profile: .qwen35, vocabulary: vocabulary,
            initialPhase: .answer, maxTokens: 256)
        var state = constraint.initialState
        for token in tokenizer.encode(text: "{\"name\": \"Ada Lovelace\", \"born\": 1815, \"tags\": [\"é\", null]}",
                                      addSpecialTokens: false) {
            state = try #require(constraint.nextState(state: state, tokenID: token), "token \(token)")
        }
        #expect(constraint.nextState(state: state, tokenID: 248046) == -1)
        print("qwen-json-answer-vocabulary-build: \(elapsed)")
    }
}
