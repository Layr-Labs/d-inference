import DarkbloomClusterQualification
import Foundation
import Tokenizers

/// The registered artifact's own tokenizer, for turning fixed text into the
/// prompt of a qualification request and selected tokens back into text. The
/// tokenizer files are first checked against the artifact's manifest, whose
/// hash is the one the runtime pins.
public struct PromptTokenizer: Sendable {
    public static let registeredManifestSHA256 = "4f2735026cc7b40ee2c886ee53fb8755816c0001c4c69c141a61d5f56ff22aa4"
    /// The manifest pins of the registered artifacts, as the runtime pins them,
    /// and the model each one is. A tokenizer under any other manifest is refused.
    public static let registeredManifests: [(sha256: String, modelID: String)] = [
        (registeredManifestSHA256, "registered_qwen35_9b"),
        ("d1239a5bc6d26d5ce4bf87f22270e3a703f4942e3d0d779948b4f65410df6dcc", "registered_qwen38_27b"),
        ("1807c0cc834ac472a71013f6951ab82a620e7bc6b004a24866c9340d90dc5abb", "registered_qwen35_35b_a3b"),
        ("19a69c0c992dc4fda29d72f4f18a039865bccd8d9c6e0efe1104c4fa8b8b0ffc", "registered_qwen36_35b_a3b"),
        ("e6871c8df1f9d30895ff5caf84a40fe902cf8771cda56a2b9f087991ca34c1e4", "registered_ternary_bonsai_2_27b"),
        ("c226d5cf4ecea1c6f299c2a8ebaa8686a89be12750b45fa6fc910cb078b19c13", "registered_ternary_bonsai_2_9b"),
        ("fd6491377ed831c22ccb168ce1cc71b003a3b9a0dccdcb53a08f31e8208cee78", "registered_nemotron35_lightning"),
        // GPT-OSS prompts are raw text: its chat format is not the wrapper below.
        ("fe9f986d5574db34202ab32a16a99dd109b3233c904e87edc8cbfe40bc5a3461", "registered_gpt_oss_20b"),
        ("56c0a624037457a7e9705f765e50ff346c5fb4eec410bdfee443b20dbca56565", "registered_mimo_v26_flash_mopd"),
        ("e1bd0a99f0eeb451bd1be9baf700c7563816e3375bb24cdc6d1c8933cb36799e", "registered_gemma4_26b_qat_4bit"),
        ("534b6e9eb9c4f93c24f12e191e022865388c124f8021c213852cc3c2d51f795c", "registered_gemma4_26b"),
        ("84b34231bc57b36a2d412f2fb0608a7828437915806241ca212b30912ceabbbb", "registered_gemma4_26b_8bit"),
        ("ae8750273ae85bbcc9d77dfb3b8af8dd11bfb25622524689be2ee3a71bece570", "registered_glm53_flash"),
    ]
    /// Models whose chat format is not the wrapper below. Their prompts are raw
    /// text only, so a request never carries a chat format the model does not have.
    static let rawTextOnlyModelIDs: Set<String> = ["registered_gpt_oss_20b"]
    static let userPrefix = "<|im_start|>user\n"
    /// The artifact's template with thinking disabled.
    static let assistantSuffix = "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    /// MiMo's own template closes the turn without a newline and writes an
    /// empty thinking block. Every other registered model uses the pair above
    /// unless `chatWrapper` names its own.
    static let assistantSuffixes = [
        "registered_mimo_v26_flash_mopd": "<|im_end|><|im_start|>assistant\n<think></think>",
    ]
    /// What a registered artifact's own template puts around one user turn
    /// with thinking disabled. Nemotron's template always opens with a system
    /// turn, empty when the request has none, and closes thinking at once.
    /// Gemma's opens with its start-of-sequence token and closes the model
    /// turn's empty thought channel. MiMo's suffix is in `assistantSuffixes`.
    static func chatWrapper(modelID: String) -> (prefix: String, suffix: String) {
        if modelID == "registered_nemotron35_lightning" {
            return ("<|im_start|>system\n<|im_end|>\n<|im_start|>user\n", "<|im_end|>\n<|im_start|>assistant\n<think></think>")
        }
        // GLM's template has no thinking switch: it renders its default
        // reasoning-effort system turn and opens the assistant's thinking block.
        if modelID == "registered_glm53_flash" {
            return ("[gMASK]<sop><|system|>Reasoning Effort: Max<|user|>", "<|assistant|><think>")
        }
        if modelID.hasPrefix("registered_gemma4_") {
            return ("<bos>\n<|turn>user\n", "<turn|>\n<|turn>model\n<|channel>thought\n<channel|>")
        }
        return (userPrefix, assistantSuffixes[modelID] ?? assistantSuffix)
    }

    public let tokenizerSHA256: String
    /// The registered model whose manifest the tokenizer files were checked against.
    public let modelID: String
    private let tokenizer: any Tokenizer

    public static func load(modelDirectory: URL) async throws -> Self {
        struct Manifest: Decodable {
            struct Entry: Decodable { let path: String, sha256: String }
            let files: [Entry]
        }
        let manifestData = try QualificationFiles.read(modelDirectory.appendingPathComponent("manifest.json"),
                                                       maximumBytes: 4 << 20)
        let manifestSHA256 = QualificationHash.sha256(manifestData)
        guard let registered = registeredManifests.first(where: { $0.sha256 == manifestSHA256 }) else {
            throw QualificationError("manifest.json is not a registered model's manifest")
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
        return .init(tokenizerSHA256: tokenizerSHA256, modelID: registered.modelID,
                     tokenizer: try await AutoTokenizer.from(modelFolder: modelDirectory))
    }

    public func decode(_ tokenIDs: [Int]) -> String { tokenizer.decode(tokens: tokenIDs, skipSpecialTokens: false) }

    public func encodeRaw(_ text: String) -> [Int] { tokenizer.encode(text: text, addSpecialTokens: false) }

    /// A user turn and the assistant's opening, as the artifact's chat template
    /// renders them with thinking disabled. With `promptTokenCount`, the text's
    /// tokens are repeated and cut so the whole prompt has exactly that many
    /// tokens; the chat wrapper around the text is never cut.
    public func encodeChat(userText: String, promptTokenCount: Int?) throws -> (tokenIDs: [Int], source: QualificationPromptSource) {
        guard !Self.rawTextOnlyModelIDs.contains(modelID) else {
            throw QualificationError("\(modelID) has its own chat format; write its request from raw text (--raw-text-file)")
        }
        let wrapper = Self.chatWrapper(modelID: modelID)
        let prefix = encodeRaw(wrapper.prefix), suffix = encodeRaw(wrapper.suffix)
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
