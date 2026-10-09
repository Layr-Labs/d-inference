import DarkbloomClusterQualification
import Foundation
import Tokenizers

/// The registered artifact's own tokenizer, for turning fixed text into the
/// prompt of a qualification request and selected tokens back into text. The
/// tokenizer files are first checked against the artifact's manifest, whose
/// hash is the one the runtime pins.
public struct PromptTokenizer: Sendable {
    public static let registeredManifestSHA256 = "4f2735026cc7b40ee2c886ee53fb8755816c0001c4c69c141a61d5f56ff22aa4"
    static let userPrefix = "<|im_start|>user\n"
    /// The artifact's template with thinking disabled.
    static let assistantSuffix = "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"

    public let tokenizerSHA256: String
    private let tokenizer: any Tokenizer

    public static func load(modelDirectory: URL) async throws -> Self {
        struct Manifest: Decodable {
            struct Entry: Decodable { let path: String, sha256: String }
            let files: [Entry]
        }
        let manifestData = try QualificationFiles.read(modelDirectory.appendingPathComponent("manifest.json"),
                                                       maximumBytes: 4 << 20)
        guard QualificationHash.sha256(manifestData) == registeredManifestSHA256 else {
            throw QualificationError("manifest.json is not the registered Qwen3.5 9B manifest")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        var tokenizerSHA256 = ""
        for name in ["tokenizer.json", "tokenizer_config.json", "chat_template.jinja"] {
            let actual = try QualificationHash.file(modelDirectory.appendingPathComponent(name), maximumBytes: 64 << 20)
            guard manifest.files.first(where: { $0.path == name })?.sha256 == actual else {
                throw QualificationError("\(name) differs from the registered manifest")
            }
            if name == "tokenizer.json" { tokenizerSHA256 = actual }
        }
        return .init(tokenizerSHA256: tokenizerSHA256,
                     tokenizer: try await AutoTokenizer.from(modelFolder: modelDirectory))
    }

    public func decode(_ tokenIDs: [Int]) -> String { tokenizer.decode(tokens: tokenIDs, skipSpecialTokens: false) }

    public func encodeRaw(_ text: String) -> [Int] { tokenizer.encode(text: text, addSpecialTokens: false) }

    /// A user turn and the assistant's opening, as the artifact's chat template
    /// renders them with thinking disabled. With `promptTokenCount`, the text's
    /// tokens are repeated and cut so the whole prompt has exactly that many
    /// tokens; the chat wrapper around the text is never cut.
    public func encodeChat(userText: String, promptTokenCount: Int?) throws -> (tokenIDs: [Int], source: QualificationPromptSource) {
        let prefix = encodeRaw(Self.userPrefix), suffix = encodeRaw(Self.assistantSuffix)
        var body = encodeRaw(userText)
        guard !body.isEmpty else { throw QualificationError("The prompt text produced no tokens") }
        var matches: Bool?
        if let promptTokenCount {
            let room = promptTokenCount - prefix.count - suffix.count
            guard room >= 1 else { throw QualificationError("The requested token count is smaller than the chat wrapper") }
            let unit = body
            while body.count < room { body += unit }
            body = Array(body.prefix(room))
        } else {
            // Unmodified text: this must be exactly what the artifact's own template produces.
            let rendered = try? tokenizer.applyChatTemplate(messages: [["role": "user", "content": userText]],
                tools: nil, additionalContext: ["enable_thinking": false])
            matches = rendered.map { $0 == prefix + body + suffix }
        }
        let source = QualificationPromptSource(kind: "chatText",
            description: "One user turn in the artifact's chat format with thinking disabled"
                + (promptTokenCount == nil ? "" : "; the text's tokens are repeated and cut to an exact prompt length"),
            text: userText, textSHA256: QualificationHash.sha256(Data(userText.utf8)), tokenizerSHA256: tokenizerSHA256,
            bodyTokenCount: body.count, matchesArtifactChatTemplate: matches)
        return (prefix + body + suffix, source)
    }

    public func rawSource(text: String, tokenCount: Int) -> QualificationPromptSource {
        .init(kind: "rawText", description: "Text tokenized as written, with no chat format",
              text: text, textSHA256: QualificationHash.sha256(Data(text.utf8)), tokenizerSHA256: tokenizerSHA256,
              bodyTokenCount: tokenCount)
    }
}
