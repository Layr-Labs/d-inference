import Testing
@testable import ProviderCore

@Suite("Native Qwen4 tool framing vocabulary")
struct Qwen4ToolFramingVocabularyTests {
    @Test func nativeByteLevelProjectionPreservesOnlyFramingMeaning() {
        #expect(Qwen4ToolFramingVocabulary.framingProjection("ĠaĊ<tool_call>\\\"") == " a\n<tool_call>\\\"")
        #expect(!Qwen4ToolFramingVocabulary.framingProjection("é雪").contains("<"))
    }
}
