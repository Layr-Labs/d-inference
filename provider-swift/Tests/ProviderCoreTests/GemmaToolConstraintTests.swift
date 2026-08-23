import Foundation
import MLXLMCommon
import MLXLMServer
@testable import ProviderCore
import Testing

struct ASCIIConstraintTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        text.utf8.map(Int.init)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        String(decoding: tokenIds.compactMap {
            $0 >= 0 && $0 < 128 ? UInt8($0) : nil
        }, as: UTF8.self)
    }
    func convertTokenToId(_ token: String) -> Int? {
        if token == "<eos>" { return 128 }
        let bytes = Array(token.utf8)
        return bytes.count == 1 ? Int(bytes[0]) : nil
    }
    func convertIdToToken(_ id: Int) -> String? {
        if id == 128 { return "<eos>" }
        guard id >= 0, id < 128, let scalar = UnicodeScalar(id) else { return nil }
        return String(Character(scalar))
    }
    let bosToken: String? = nil
    let eosToken: String? = "<eos>"
    let unknownToken: String? = nil
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [] }
}

@Suite("Gemma CBv2 tool constraints")
struct GemmaToolConstraintTests {
    static let realGemmaModelID =
        "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
    static var hasRealGemmaTokenizerFixture: Bool {
        ModelScanner.resolveLocalPath(modelID: realGemmaModelID) != nil
    }

    let tokenizer = TokenizerHandle(
        ASCIIConstraintTokenizer(),
        toolConstraintContractVerified: true)

    @Test("tool grammar accepts only exact Gemma types and pinned template bytes")
    func pinnedTemplateContract() throws {
        #expect(Gemma4ToolConstraintContract.supports(modelType: "gemma4_text"))
        #expect(!Gemma4ToolConstraintContract.supports(modelType: "gemma4_assistant_v2"))
        #expect(!Gemma4ToolConstraintContract.supports(modelType: nil))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("drifted template".utf8).write(
            to: directory.appendingPathComponent("chat_template.jinja"))
        #expect(
            !Gemma4ToolConstraintContract.isVerified(
                modelType: "gemma4_text",
                modelDirectory: directory))
    }

    func tool(
        name: String = "weather",
        parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "city": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("city")]),
            "additionalProperties": .bool(false),
        ])
    ) -> OpenAITool {
        OpenAITool(function: .init(
            name: name, description: "Weather", parameters: parameters))
    }

    func request(
        choice: OpenAIToolChoice,
        tools: [OpenAITool]? = nil,
        parallel: Bool = false
    ) -> OpenAIChatCompletionRequest {
        OpenAIChatCompletionRequest(
            model: "gemma-4-test",
            messages: [.init(role: .user, content: .text("weather"))],
            tools: tools ?? [tool()],
            toolChoice: choice,
            parallelToolCalls: parallel,
            maxTokens: 128)
    }
}
