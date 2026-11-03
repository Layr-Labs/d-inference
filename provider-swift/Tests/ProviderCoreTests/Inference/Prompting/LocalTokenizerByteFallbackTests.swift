// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// A character outside the vocabulary is written as `<0xHH>` tokens. Client text must carry it
/// wherever it falls: swift-transformers' `ByteFallbackDecoder` drops a trailing run, so Gemma 4
/// lost a reply's last emoji, and a restart inside a run corrupted a long reply.
@Suite("Local tokenizer byte fallback")
struct LocalTokenizerByteFallbackTests {
    private static let texts = [
        "all zipped up 🗜", "🗜", "ends 갂", "a🗜b🗜", "🗜🗜", "mixed 丌 and ∛ then 🩵", "plain ascii",
    ]
    private static let promptCacheEnvironments: [[String: String]] = [[:], ["DARKBLOOM_TTFT_PROMPT_CACHE": "0"]]

    /// A character-level tokenizer with Gemma 4's decoder sequence: ASCII has its own tokens and
    /// everything else is byte tokens.
    private func tokenizerDirectory(
        decoder: [String: Any]? = nil, byteTokens: ClosedRange<Int>? = 0...255, literal: [String] = []
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("byte-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var vocabulary: [String: Int] = ["<unk>": 0, "<eos>": 1]
        for value in 32...126 { vocabulary[String(UnicodeScalar(value)!)] = vocabulary.count }
        if let byteTokens {
            for value in byteTokens { vocabulary[String(format: "<0x%02X>", value)] = vocabulary.count }
        }
        for token in literal { vocabulary[token] = vocabulary.count }
        let sequence: [String: Any] = [
            "type": "Sequence",
            "decoders": [
                ["type": "Replace", "pattern": ["String": "▁"], "content": " "] as [String: Any],
                ["type": "ByteFallback"], ["type": "Fuse"],
            ],
        ]
        let config: [String: Any] = [
            "tokenizer_class": "GemmaTokenizer", "processor_class": "Gemma4Processor", "unk_token": "<unk>",
            "clean_up_tokenization_spaces": false,
        ]
        let data: [String: Any] = [
            "model": ["type": "BPE", "vocab": vocabulary, "merges": [String](), "unk_token": "<unk>"],
            "added_tokens": [["id": 1, "content": "<eos>", "special": true] as [String: Any]],
            "decoder": decoder ?? sequence,
        ]
        try JSONSerialization.data(withJSONObject: config).write(
            to: directory.appendingPathComponent("tokenizer_config.json"))
        try JSONSerialization.data(withJSONObject: data).write(to: directory.appendingPathComponent("tokenizer.json"))
        return directory
    }

    /// The IDs the model generates for `text`, without going through the encoder.
    private func ids(_ text: String, _ tokenizer: any MLXLMCommon.Tokenizer) throws -> [Int] {
        var ids: [Int] = []
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                ids.append(try #require(tokenizer.convertTokenToId(String(scalar))))
            } else {
                for byte in String(scalar).utf8 {
                    ids.append(try #require(tokenizer.convertTokenToId(String(format: "<0x%02X>", byte))))
                }
            }
        }
        return ids
    }

    private func streamed(_ ids: [Int], _ tokenizer: any MLXLMCommon.Tokenizer) -> String {
        let detokenizer = DetokenizerV2(tokenizer: tokenizer)
        var text = ""
        for id in ids { text += detokenizer.append(id) }
        return text + detokenizer.flush()
    }

    @Test("a decode keeps a trailing run", arguments: promptCacheEnvironments)
    func decodeKeepsTrailingRun(environment: [String: String]) async throws {
        let directory = try tokenizerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = try await LocalTokenizerLoader(environment: environment).load(from: directory)
        for text in Self.texts {
            let tokens = try ids(text, tokenizer)
            #expect(tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false) == text)
            #expect(tokenizer.decode(tokenIds: tokens, skipSpecialTokens: true) == text)
        }
    }

    @Test("a stream carries every character once", arguments: promptCacheEnvironments)
    func streamCarriesEveryCharacter(environment: [String: String]) async throws {
        let directory = try tokenizerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = try await LocalTokenizerLoader(environment: environment).load(from: directory)
        for text in Self.texts {
            #expect(streamed(try ids(text, tokenizer), tokenizer) == text)
        }
    }

    @Test("a reply of byte tokens alone keeps all of them")
    func allByteReply() async throws {
        let directory = try tokenizerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        // Longer than any bound a walk might take, and a control character written as a byte.
        let text = String(repeating: "갂🗜丌", count: 100) + "\r"
        let tokens = try text.unicodeScalars.flatMap { scalar in
            try String(scalar).utf8.map { byte in
                try #require(tokenizer.convertTokenToId(String(format: "<0x%02X>", byte)))
            }
        }
        #expect(tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false) == text)
        #expect(streamed(tokens, tokenizer) == text)
    }

    @Test("a segment restart does not land inside a run")
    func restartInsideARun() async throws {
        let directory = try tokenizerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        // The segment's soft cap is 256 tokens: put the four bytes on every side of it, twice.
        for padding in 248...258 {
            let text = String(repeating: "a", count: padding) + "🗜" + String(repeating: "b", count: padding) + "🗜 end"
            #expect(streamed(try ids(text, tokenizer), tokenizer) == text)
        }
    }

    @Test("a trailing special token does not hide a run")
    func trailingSpecialToken() async throws {
        let directory = try tokenizerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        let eos = try #require(tokenizer.convertTokenToId("<eos>"))
        let tokens = try ids("zipped 🗜", tokenizer) + [eos]
        #expect(tokenizer.decode(tokenIds: tokens, skipSpecialTokens: true) == "zipped 🗜")
        #expect(tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false) == "zipped 🗜<eos>")
    }

    @Test("a run cut mid-character ends in one replacement character")
    func cutMidCharacter() async throws {
        let directory = try tokenizerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        let tokens = Array(try ids("ab🗜", tokenizer).dropLast(2))
        #expect(tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false) == "ab\u{FFFD}")
        #expect(streamed(tokens, tokenizer) == "ab\u{FFFD}")
    }

    @Test("another decoder keeps its spelling of a literal byte token")
    func otherDecoderKeepsSpelling() async throws {
        let directory = try tokenizerDirectory(decoder: ["type": "Fuse"], byteTokens: nil, literal: ["<0x41>"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        let literal = try #require(tokenizer.convertTokenToId("<0x41>"))
        #expect(tokenizer.decode(tokenIds: [literal], skipSpecialTokens: false) == "<0x41>")
        #expect(tokenizer.decode(tokenIds: try ids("a", tokenizer) + [literal], skipSpecialTokens: false) == "a<0x41>")
    }

    @Test("the unknown token is not read as a byte")
    func unknownTokenIsNotAByte() async throws {
        // Only some byte tokens exist, so the others convert to the unknown ID.
        let directory = try tokenizerDirectory(byteTokens: 0xF0...0xFF)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The probe reads whichever byte token a dictionary lists first, so load it more than once.
        for _ in 0..<40 {
            let tokenizer = try await LocalTokenizerLoader().load(from: directory)
            let unknown = try #require(tokenizer.convertTokenToId("<unk>"))
            #expect(tokenizer.decode(tokenIds: try ids("a", tokenizer) + [unknown], skipSpecialTokens: false) == "a<unk>")
        }
    }
}
