import XCTest

@testable import ProviderCoreFoundation

final class HarmonySanitizationTests: XCTestCase {

    func testFinalOnlyReturnsAnswer() {
        XCTAssertEqual(
            stripHarmonyChannelFraming(fromAssistantContent: "<|channel|>final<|message|>Hello"),
            "Hello")
    }

    func testAnalysisPlusFinalDropsAnalysis() {
        XCTAssertEqual(
            stripHarmonyChannelFraming(
                fromAssistantContent: "<|channel|>analysis<|message|>think<|end|><|channel|>final<|message|>Answer"),
            "Answer")
    }

    func testFinalEndTerminatorTruncatesAnswer() {
        XCTAssertEqual(
            stripHarmonyChannelFraming(fromAssistantContent: "<|channel|>final<|message|>Answer<|end|>"),
            "Answer")
    }

    func testFinalReturnTerminatorTruncatesAnswer() {
        XCTAssertEqual(
            stripHarmonyChannelFraming(fromAssistantContent: "<|channel|>final<|message|>Answer<|return|>"),
            "Answer")
    }

    func testAnalysisOnlyReturnsEmptyInferenceContent() {
        XCTAssertEqual(
            stripHarmonyChannelFraming(
                fromAssistantContent: "<|channel|>analysis<|message|>just thinking<|end|>"),
            "")
    }

    func testNoTagsReturnsInputByteIdentical() {
        let input = "plain text"
        let output = stripHarmonyChannelFraming(fromAssistantContent: input)
        XCTAssertEqual(output, input)
        XCTAssertTrue(output.utf8.elementsEqual(input.utf8))
    }

    func testMultipleFinalsLastWins() {
        XCTAssertEqual(
            stripHarmonyChannelFraming(
                fromAssistantContent: "<|channel|>final<|message|>First<|end|><|channel|>final<|message|>Second"),
            "Second")
    }

    func testAssistantMessageStringFieldsCleanedWhileUserUntouched() {
        let framed = "<|channel|>analysis<|message|>think<|end|><|channel|>final<|message|>Answer"
        let assistant: [String: Any] = [
            "role": "assistant",
            "content": framed,
            "thinking": framed,
            "reasoning_content": framed,
            "parts": [["type": "text", "text": framed]],
        ]
        let user: [String: Any] = ["role": "user", "content": framed]

        let cleanedAssistant = stripMessageForTest(assistant)
        XCTAssertEqual(cleanedAssistant["content"] as? String, "Answer")
        XCTAssertEqual(cleanedAssistant["thinking"] as? String, "Answer")
        XCTAssertEqual(cleanedAssistant["reasoning_content"] as? String, "Answer")
        XCTAssertNotNil(cleanedAssistant["parts"] as? [[String: String]])

        let contentParts = [["type": "text", "text": framed]]
        let assistantWithContentParts: [String: Any] = [
            "role": "assistant",
            "content": contentParts,
        ]
        let cleanedContentParts = stripMessageForTest(assistantWithContentParts)
        XCTAssertEqual(cleanedContentParts["content"] as? [[String: String]], contentParts)

        let cleanedUser = stripMessageForTest(user)
        XCTAssertEqual(cleanedUser["content"] as? String, framed)
    }

    private func stripMessageForTest(_ message: [String: Any]) -> [String: Any] {
        guard (message["role"] as? String) == "assistant" else { return message }

        var output = message
        for key in ["content", "thinking", "reasoning_content"] {
            if let text = output[key] as? String {
                output[key] = stripHarmonyChannelFraming(fromAssistantContent: text)
            }
        }
        return output
    }
}
