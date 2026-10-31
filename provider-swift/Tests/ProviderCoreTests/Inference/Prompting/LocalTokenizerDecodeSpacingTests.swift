// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import Testing
import Tokenizers

@testable import ProviderCore

/// Decoded text must spell what the tokens spell. Gemma 4's published tokenizer config has no
/// `clean_up_tokenization_spaces` key, and swift-transformers reads that as cleanup on, so a
/// served reply lost the space in `git add .` and repeated the quote in `'start'`.
@Suite("Local tokenizer decode spacing")
struct LocalTokenizerDecodeSpacingTests {
    private static let exactTexts = [
        "git add .", "bash ./run.sh && cp .env.example .env", "rm -rf .git", "x != y ? a : b",
        "name = 'start'", "s = ' ' + t", "a . b , c ? d !", "x ' value ' y", "we 're", "I 'm", "it 's",
        "they 've", "do n't", ".foo .bar {", "function 'record_payload'", "  exact  spaces  ",
    ]
    private static let promptCacheEnvironments: [[String: String]] = [[:], ["DARKBLOOM_TTFT_PROMPT_CACHE": "0"]]

    /// A character-level tokenizer the way Gemma 4's config declares it: no cleanup key unless asked.
    private func tokenizerDirectory(cleanup: Any? = nil) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("decode-spacing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var config: [String: Any] = [
            "tokenizer_class": "GemmaTokenizer", "processor_class": "Gemma4Processor", "unk_token": "<unk>",
        ]
        if let cleanup { config["clean_up_tokenization_spaces"] = cleanup }
        var vocabulary: [String: Int] = ["<unk>": 0]
        for value in 32...126 { vocabulary[String(UnicodeScalar(value)!)] = value - 31 }
        let data: [String: Any] = [
            "model": ["type": "BPE", "vocab": vocabulary, "merges": [String](), "unk_token": "<unk>"],
            "decoder": ["type": "Fuse"],
        ]
        try JSONSerialization.data(withJSONObject: config).write(
            to: directory.appendingPathComponent("tokenizer_config.json"))
        try JSONSerialization.data(withJSONObject: data).write(to: directory.appendingPathComponent("tokenizer.json"))
        return directory
    }

    @Test("an absent cleanup key keeps decoded text exact", arguments: promptCacheEnvironments)
    func absentKeyKeepsTextExact(environment: [String: String]) async throws {
        let directory = try tokenizerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = try await LocalTokenizerLoader(environment: environment).load(from: directory)
        for text in Self.exactTexts {
            let tokens = tokenizer.encode(text: text, addSpecialTokens: false)
            #expect(tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false) == text)
            #expect(tokenizer.decode(tokenIds: tokens, skipSpecialTokens: true) == text)
        }
    }

    @Test("a stream carries every byte once", arguments: promptCacheEnvironments)
    func streamCarriesEveryByteOnce(environment: [String: String]) async throws {
        let directory = try tokenizerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = try await LocalTokenizerLoader(environment: environment).load(from: directory)
        for text in Self.exactTexts {
            let detokenizer = DetokenizerV2(tokenizer: tokenizer)
            var streamed = ""
            for token in tokenizer.encode(text: text, addSpecialTokens: false) {
                streamed += detokenizer.append(token)
            }
            streamed += detokenizer.flush()
            #expect(streamed == text)
        }
    }

    @Test("an explicit cleanup value is kept", arguments: [false, true])
    func explicitValueIsKept(cleanup: Bool) async throws {
        let directory = try tokenizerDirectory(cleanup: cleanup)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        let tokens = tokenizer.encode(text: "a .", addSpecialTokens: false)
        #expect(tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false) == (cleanup ? "a." : "a ."))
    }

    @Test("a null cleanup value reads as absent")
    func nullValueReadsAsAbsent() async throws {
        let directory = try tokenizerDirectory(cleanup: NSNull())
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        let tokens = tokenizer.encode(text: "a .", addSpecialTokens: false)
        #expect(tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false) == "a .")
    }

    @Test("input IDs and the published config stay as they are")
    func inputIDsAndConfigStay() async throws {
        let directory = try tokenizerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: directory.appendingPathComponent("tokenizer_config.json"))
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        let untouched = try await AutoTokenizer.from(modelFolder: directory)
        for text in Self.exactTexts {
            #expect(tokenizer.encode(text: text, addSpecialTokens: false)
                == untouched.encode(text: text, addSpecialTokens: false))
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("tokenizer_config.json")) == original)
    }
}
