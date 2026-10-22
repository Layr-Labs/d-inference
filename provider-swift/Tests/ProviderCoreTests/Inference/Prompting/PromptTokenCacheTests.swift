// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import Hub
import MLXLMCommon
import ProviderCoreFoundation
import Testing

@testable import ProviderBenchmark
@testable import ProviderCore

/// The prompt token cache must return exactly the unchanged tokenizer path's
/// token IDs. Synthetic tokenizers cover the three pre-tokenizer families of
/// the served models (Qwen split + byte level, GPT-2 byte level, Gemma
/// metaspace with byte fallback) without model downloads; the live case runs
/// the same comparison over real local artifacts.
@Suite("Prompt token cache")
struct PromptTokenCacheTests {
    @Test("piecewise encoding equals whole-text encoding", arguments: SyntheticTokenizer.Family.allCases)
    func piecewiseEncodingMatches(family: SyntheticTokenizer.Family) async throws {
        let fixture = try SyntheticTokenizer(family: family)
        defer { fixture.remove() }
        let tokenizer = try await LocalTokenizerLoader().load(from: fixture.directory)
        let cache = try #require((tokenizer as? any PromptTokenCaching)?.promptTokenCache)
        #expect(cache.isActive)

        var generator = FragmentGenerator(seed: UInt64(family.rawValue.utf8.reduce(0) { $0 &* 31 &+ Int($1) }))
        for index in 0..<400 {
            let text = generator.text(fragments: 1 + index % 40)
            let expected = tokenizer.encode(text: text, addSpecialTokens: false)
            #expect(cache.encode(text, scope: "a") == expected, "cold: \(text.debugDescription)")
            #expect(cache.encode(text, scope: "a") == expected, "stored: \(text.debugDescription)")
        }
    }

    @Test("chat requests tokenize identically with and without the cache", arguments: SyntheticTokenizer.Family.allCases)
    func chatRequestsMatch(family: SyntheticTokenizer.Family) async throws {
        let fixture = try SyntheticTokenizer(family: family)
        defer { fixture.remove() }
        let tokenizer = try await LocalTokenizerLoader().load(from: fixture.directory)
        #expect(PromptPreparationProbe.promptCacheIsActive(tokenizer))

        var generator = FragmentGenerator(seed: 7)
        var messages: [[String: Any]] = [["role": "system", "content": "Be brief. " + generator.text(fragments: 8)]]
        for turn in 0..<6 {
            messages.append(["role": "user", "content": generator.text(fragments: 12 + turn)])
            let probe = try PromptPreparationProbe(body: Self.body(messages), modelType: nil)
            let reference = try probe.promptTokens(tokenizer: tokenizer, promptCacheScope: nil)
            // Turn N reuses the pieces of turn N-1; the repeat is fully stored.
            #expect(try probe.promptTokens(tokenizer: tokenizer, promptCacheScope: "tenant") == reference)
            #expect(try probe.promptTokens(tokenizer: tokenizer, promptCacheScope: "tenant") == reference)
            messages.append(["role": "assistant", "content": generator.text(fragments: 10)])
        }
    }

    @Test("pieces are partitioned by cache scope")
    func scopesDoNotShareEntries() async throws {
        let fixture = try SyntheticTokenizer(family: .qwen)
        defer { fixture.remove() }
        let tokenizer = try await LocalTokenizerLoader().load(from: fixture.directory)
        let cache = try #require((tokenizer as? any PromptTokenCaching)?.promptTokenCache)
        let text = "<|im_start|>user\nshared history<|im_end|>\n<|im_start|>assistant\n"
        let before = cache.storedBytes
        _ = cache.encode(text, scope: "tenant-a")
        let afterFirst = cache.storedBytes
        _ = cache.encode(text, scope: "tenant-a")
        #expect(cache.storedBytes == afterFirst)
        _ = cache.encode(text, scope: "tenant-b")
        #expect(afterFirst > before)
        #expect(cache.storedBytes - afterFirst == afterFirst - before)
    }

    @Test("kill switch and global prefix-cache switch disable reuse")
    func environmentSwitches() {
        #expect(PromptTokenCachePolicy.isEnabled(environment: [:]))
        #expect(!PromptTokenCachePolicy.isEnabled(environment: ["DARKBLOOM_TTFT_PROMPT_CACHE": "0"]))
        #expect(!PromptTokenCachePolicy.isEnabled(environment: ["DARKBLOOM_TTFT_PROMPT_CACHE": "off"]))
        #expect(PromptTokenCachePolicy.isEnabled(environment: ["DARKBLOOM_TTFT_PROMPT_CACHE": "1"]))
        #expect(!PromptTokenCachePolicy.isEnabled(environment: [PrefixCachePolicy.environmentFlag: "0"]))
        #expect(PromptTokenCachePolicy.capacityBytes(environment: [:]) == 32 << 20)
        #expect(PromptTokenCachePolicy.capacityBytes(environment: ["DARKBLOOM_TTFT_PROMPT_CACHE_MB": "0"]) == 0)
        #expect(PromptTokenCachePolicy.capacityBytes(environment: ["DARKBLOOM_TTFT_PROMPT_CACHE_MB": "-1"]) == 32 << 20)
        #expect(PromptTokenCachePolicy.verificationInterval(environment: ["DARKBLOOM_TTFT_PROMPT_CACHE_VERIFY": "0"]) == 0)
        // Each rollback must reach the launchd provider job.
        let rollback = [
            PromptTokenCachePolicy.environmentKey: "0", PromptTokenCachePolicy.capacityEnvironmentKey: "0",
            PromptTokenCachePolicy.verifyEnvironmentKey: "0",
        ]
        #expect(LaunchAgent.passthroughEnvironment(from: rollback) == rollback)
    }

    @Test("splitter declines tokenizers outside the exact conditions")
    func splitterDeclines() throws {
        let identity: [String: Any] = ["type": "ByteLevel"]
        #expect(PromptPieceSplitter(tokenizerData: Self.data(added: ["<a>"], postProcessor: identity)) != nil)
        #expect(PromptPieceSplitter(tokenizerData: Self.data(added: ["<a>"], lstrip: true, postProcessor: identity)) == nil)
        #expect(PromptPieceSplitter(tokenizerData: Self.data(added: [""], postProcessor: identity)) == nil)
        #expect(PromptPieceSplitter(tokenizerData: Self.data(
            added: ["<a>"], postProcessor: ["type": "RobertaProcessing", "sep": ["</s>", 2], "cls": ["<s>", 0]])) == nil)
        let template: [String: Any] = [
            "type": "TemplateProcessing",
            "single": [["SpecialToken": ["id": "<s>", "type_id": 0]], ["Sequence": ["id": "A", "type_id": 0]]],
            "pair": [["Sequence": ["id": "A", "type_id": 0]], ["Sequence": ["id": "B", "type_id": 1]]],
        ]
        #expect(PromptPieceSplitter(tokenizerData: Self.data(added: ["<a>"], postProcessor: template)) != nil)
        let pairSingle: [String: Any] = [
            "type": "TemplateProcessing",
            "single": [["Sequence": ["id": "A", "type_id": 0]], ["Sequence": ["id": "B", "type_id": 1]]],
            "pair": [] as [Any],
        ]
        #expect(PromptPieceSplitter(tokenizerData: Self.data(added: ["<a>"], postProcessor: pairSingle)) == nil)
        #expect(PromptPieceSplitter(tokenizerData: Self.data(
            added: ["<a>"], postProcessor: ["type": "Sequence", "processors": [identity, identity]])) != nil)
    }

    @Test("ambiguous added tokens never become cut points")
    func ambiguousTokensAreNotCuts() throws {
        // "[A]" is a prefix of "[A]B"; the suffix "|" of "<x|" overlaps "|y>".
        let splitter = try #require(PromptPieceSplitter(tokenizerData: Self.data(
            added: ["[A]", "[A]B", "<x|", "|y>", "<z>"], postProcessor: ["type": "ByteLevel"])))
        #expect(splitter.cutTokens == ["<x|", "<z>"])
        var text = "a<x|b<z>c|y>d<x|y>[A]B<z>"
        let cuts = text.withUTF8 { splitter.cutOffsets(in: $0) }
        #expect(cuts == [1, 5, 13, 22])
    }

    @Test("token store evicts least recently used pieces within its byte bound")
    func storeEviction() {
        let store = PromptPieceTokenStore(capacityBytes: 4096)
        let keys = (0..<64).map { Self.digest($0) }
        store.insert([(keys[0], Array(repeating: 1, count: 16))])
        for index in 1..<64 {
            _ = store.lookup([keys[0]])
            store.insert([(keys[index], Array(repeating: Int32(index), count: 16))])
        }
        #expect(store.storedBytes <= 4096)
        #expect(store.lookup([keys[0]])[0] != nil)
        #expect(store.lookup([keys[1]])[0] == nil)
        #expect(store.lookup([keys[63]])[0] == Array(repeating: 63, count: 16))
        // One piece above an eighth of the capacity is never stored.
        store.insert([(keys[1], Array(repeating: 1, count: 200))])
        #expect(store.lookup([keys[1]])[0] == nil)
        let disabled = PromptPieceTokenStore(capacityBytes: 0)
        disabled.insert([(keys[2], [1])])
        #expect(disabled.storedBytes == 0)
    }

    @Test("a background comparison that disagrees with the unchanged path disables reuse")
    func backgroundMismatchDisablesReuse() async throws {
        let (fixture, tokenizer, cache) = try await Self.markerTemplateTokenizer()
        defer { fixture.remove() }
        let caching = try #require(tokenizer as? any PromptTokenCaching)
        let messages = Self.toolTurn(then: "diverge")
        let unchanged = try tokenizer.applyChatTemplate(messages: messages, tools: nil, additionalContext: nil)
        let cached = try caching.applyChatTemplate(
            messages: messages, tools: nil, additionalContext: nil, promptCacheScope: "tenant")
        #expect(cached != unchanged)

        try await Self.awaitDisabled(cache)
        #expect(try caching.applyChatTemplate(
            messages: messages, tools: nil, additionalContext: nil, promptCacheScope: "tenant") == unchanged)
    }

    @Test("a background comparison whose unchanged path throws disables reuse")
    func backgroundReferenceFailureDisablesReuse() async throws {
        let (fixture, tokenizer, cache) = try await Self.markerTemplateTokenizer()
        defer { fixture.remove() }
        let caching = try #require(tokenizer as? any PromptTokenCaching)
        let messages = Self.toolTurn(then: "raise")
        #expect(throws: (any Error).self) {
            try tokenizer.applyChatTemplate(messages: messages, tools: nil, additionalContext: nil)
        }
        let cached = try caching.applyChatTemplate(
            messages: messages, tools: nil, additionalContext: nil, promptCacheScope: "tenant")
        #expect(!cached.isEmpty)

        try await Self.awaitDisabled(cache)
        // The scoped call now takes the unchanged path, which rejects the prompt.
        #expect(throws: (any Error).self) {
            try caching.applyChatTemplate(
                messages: messages, tools: nil, additionalContext: nil, promptCacheScope: "tenant")
        }
    }

    @Test("the prompt-preparation benchmark runs no background comparisons beside its timings")
    func benchmarkTimesWithoutBackgroundComparisons() async throws {
        let fixture = try SyntheticTokenizer(family: .qwen)
        defer { fixture.remove() }
        let result = try await PromptPreparationBenchmark.run(
            modelID: "synthetic", modelDirectory: fixture.directory, modelType: nil,
            lengths: [2048], iterations: 1)
        #expect(result.identical, "\(result.json)")
        #expect(result.json.contains("\"prompt_cache_active\" : true"))
        #expect(result.json.contains("\"prompt_cache_background_verification\" : false"))
    }

    /// Runs over real local artifacts: set `PROMPT_TOKEN_CACHE_MODEL_DIRS` to
    /// colon-separated model directories (tokenizer files and chat template).
    @Test("real chat templates tokenize identically through the cache")
    func realTemplatesMatch() async throws {
        guard let paths = ProcessInfo.processInfo.environment["PROMPT_TOKEN_CACHE_MODEL_DIRS"] else { return }
        for path in paths.split(separator: ":").map(String.init) where !path.isEmpty {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            let modelType = ModelScanner.parseConfigJSON(at: directory.appendingPathComponent("config.json")).modelType
            let result = try await PromptPreparationBenchmark.run(
                modelID: directory.lastPathComponent, modelDirectory: directory,
                modelType: modelType, lengths: [2048, 8192], iterations: 1)
            #expect(result.identical, "\(path): \(result.json)")
            #expect(result.json.contains("\"prompt_cache_active\" : true"), "\(path)")

            let tokenizer = try await LocalTokenizerLoader().load(from: directory)
            let cache = try #require((tokenizer as? any PromptTokenCaching)?.promptTokenCache)
            // Every loop rewrite that matches the served template also passes
            // the load-time comparison with it.
            let served = try String(contentsOf: directory.appendingPathComponent("chat_template.jinja"), encoding: .utf8)
            #expect(cache.templateLoopRewrites
                == ChatTemplateLoopRewrites.apply(to: normalizeSwiftJinjaTemplate(served)).applied, "\(path)")
            var generator = FragmentGenerator(seed: 11, addedTokens: cache.cutTokens)
            for index in 0..<200 {
                let text = generator.text(fragments: 1 + index % 30)
                #expect(cache.encode(text, scope: "live") == tokenizer.encode(text: text, addSpecialTokens: false),
                        "\(path): \(text.debugDescription)")
            }
        }
    }

    private static func body(_ messages: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": "synthetic", "messages": messages, "max_tokens": 16])
    }

    /// A synthetic tokenizer, loaded with the default cache settings, whose
    /// template carries the Gemma 4 tool-response scan followed by a marker
    /// check. The served scan keeps visiting the message that stops it and
    /// every later one; the rewritten scan stops there. So only the served
    /// template renders a marker's text or raises for it, while the load-time
    /// probes, which carry no marker, agree and the rewrite is kept.
    private static func markerTemplateTokenizer() async throws
        -> (SyntheticTokenizer, any MLXLMCommon.Tokenizer, PromptTokenCache)
    {
        let scan = ChatTemplateLoopRewrites.gemma4ToolResponseScan.replacements[0].old
        let template = """
            {%- set loop_messages = messages -%}
            {%- for message in loop_messages -%}
                {{- '<|im_start|>' + message['role'] + '\\n' -}}
                {%- if message['content'] is string -%}{{- message['content'] -}}{%- endif -%}
                {%- if message.get('tool_calls') -%}
                    {%- set ns_tool_scan = namespace(stopped=false) -%}
                    \(scan)
                        {%- else -%}
                            {{- '<tool_call>' + (loop_messages[k]['content'] | string) + '</tool_call>' -}}
                        {%- endif -%}
                        {%- if loop_messages[k]['content'] == 'diverge' -%}{{- ' served only' -}}{%- endif -%}
                        {%- if loop_messages[k]['content'] == 'raise' -%}{{- raise_exception('served only') -}}{%- endif -%}
                    {%- endfor -%}
                {%- endif -%}
                {{- '<|im_end|>\\n' -}}
            {%- endfor -%}
            {%- if add_generation_prompt -%}{{- '<|im_start|>assistant\\n' -}}{%- endif -%}
            """
        let fixture = try SyntheticTokenizer(family: .qwen, template: template)
        let tokenizer = try await LocalTokenizerLoader(environment: [:]).load(from: fixture.directory)
        let cache = try #require((tokenizer as? any PromptTokenCaching)?.promptTokenCache)
        #expect(cache.templateLoopRewrites == ["gemma4-tool-response-scan"])
        #expect(cache.isActive && cache.verifiesInBackground)
        return (fixture, tokenizer, cache)
    }

    /// A tool round trip followed by a user message that stops the scan.
    private static func toolTurn(then marker: String) -> [[String: any Sendable]] {
        [
            ["role": "user", "content": "Look it up."],
            ["role": "assistant", "content": "", "tool_calls": [[
                "id": "call_0", "type": "function",
                "function": ["name": "lookup", "arguments": ["key": "k"] as [String: any Sendable]] as [String: any Sendable],
            ] as [String: any Sendable]]],
            ["role": "tool", "content": "found", "tool_call_id": "call_0"],
            ["role": "user", "content": marker],
        ]
    }

    /// The background comparison runs detached, at background priority.
    private static func awaitDisabled(_ cache: PromptTokenCache) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while cache.isActive, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!cache.isActive)
    }

    private static func data(added: [String], lstrip: Bool = false, postProcessor: [String: Any]) -> Config {
        Config([
            "added_tokens": added.enumerated().map { index, content in
                ["id": 1000 + index, "content": content, "special": true, "lstrip": lstrip, "rstrip": false]
            },
            "post_processor": postProcessor,
        ] as [NSString: Any])
    }

    private static func digest(_ index: Int) -> SHA256Digest {
        withUnsafeBytes(of: index) { SHA256.hash(data: $0) }
    }
}

/// Random text built from added tokens, their fragments, Unicode edge cases,
/// whitespace runs, words, digits and contractions.
struct FragmentGenerator {
    private var state: UInt64
    private let pool: [String]

    init(seed: UInt64, addedTokens: [String] = SyntheticTokenizer.addedTokens) {
        state = seed
        let partials = addedTokens.flatMap { token -> [String] in
            let characters = Array(token)
            guard characters.count > 2 else { return [token] }
            return [String(characters.prefix(characters.count / 2)), String(characters.suffix(characters.count / 2))]
        }
        pool = addedTokens + addedTokens + partials + [
            "Hello", " world", "the", " quick", "brown", " fox", "'s", "'ll", "'RE", "don't",
            "12345", " 7", "3.14", "-", "--", "...", "!?", "(x)", "{\"k\": [1, 2]}", "/path/to/file.swift",
            " ", "  ", "   ", "\t", "\n", "\n\n", "\r\n", " \n ", "\u{3000}", "\u{00A0}",
            "é", "e\u{301}", "ñ", "Zürich", "東京", "데이터", "🙂", "👩‍💻", "\u{200D}", "x\u{0308}",
        ]
    }

    mutating func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }

    mutating func text(fragments: Int) -> String {
        (0..<fragments).map { _ in pool[next(pool.count)] }.joined()
    }
}

/// A small tokenizer written to a temporary model directory, loaded through
/// the production `LocalTokenizerLoader`.
struct SyntheticTokenizer {
    enum Family: String, CaseIterable, CustomTestStringConvertible {
        /// NFC, then a Qwen-style split regex and byte-level encoding.
        case qwen
        /// GPT-2 byte-level pre-tokenization with its built-in regex.
        case byteLevel
        /// Space-to-metaspace replacement, one word per section, byte fallback.
        case metaspace

        var testDescription: String { rawValue }
    }

    static let addedTokens = [
        "<|im_start|>", "<|im_end|>", "<think>", "</think>", "<tool_call>", "</tool_call>",
        "<|endoftext|>", "[A]", "[A]B",
    ]

    let directory: URL

    init(family: Family, template: String? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-token-cache-\(family.rawValue)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.write(["model_type": "synthetic"], to: directory.appendingPathComponent("config.json"))
        try Self.write(Self.tokenizerData(family), to: directory.appendingPathComponent("tokenizer.json"))
        var config: [String: Any] = ["tokenizer_class": "GPT2Tokenizer", "eos_token": "<|im_end|>"]
        if family == .metaspace { config["unk_token"] = "<unk>" }
        try Self.write(config, to: directory.appendingPathComponent("tokenizer_config.json"))
        try (template ?? Self.template).write(
            to: directory.appendingPathComponent("chat_template.jinja"), atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let template = """
        {%- if tools %}{{ '<|im_start|>system\\n' }}{%- for tool in tools %}{{ tool | tojson }}{%- endfor %}{{ '<|im_end|>\\n' }}{%- endif %}
        {%- for message in messages %}{{ '<|im_start|>' + message['role'] + '\\n' }}
        {%- if message['content'] is string %}{{ message['content'] }}{%- endif %}
        {%- if message['tool_calls'] is defined %}{%- for tc in message['tool_calls'] %}{{ '<tool_call>' + tc['function']['name'] + '</tool_call>' }}{%- endfor %}{%- endif %}
        {{- '<|im_end|>\\n' }}{%- endfor %}
        {%- if add_generation_prompt %}{{ '<|im_start|>assistant\\n<think>\\n' }}{%- endif %}
        """

    private static func tokenizerData(_ family: Family) -> [String: Any] {
        let added = addedTokens.enumerated().map { index, content -> [String: Any] in
            ["id": 5000 + index, "content": content, "special": true, "lstrip": false, "rstrip": false,
             "normalized": false, "single_word": false]
        }
        switch family {
        case .qwen, .byteLevel:
            let symbols = byteLevelSymbols
            var vocab: [String: Int] = [:]
            for (index, symbol) in symbols.enumerated() { vocab[symbol] = index }
            let merges = [["Ġ", "t"], ["h", "e"], ["Ġt", "he"], ["i", "n"], ["Ġ", "w"], ["o", "r"], ["Ġw", "or"],
                          ["Ġwor", "l"], ["Ġworl", "d"], ["e", "r"], ["Ċ", "Ċ"], ["Ġ", "Ġ"], ["1", "2"], ["'", "s"],
                          ["ä", "¸"], ["H", "e"], ["He", "l"], ["Hel", "l"], ["Hell", "o"]]
            for merge in merges { vocab[merge.joined()] = vocab.count }
            let preTokenizer: [String: Any] = family == .qwen
                ? ["type": "Sequence", "pretokenizers": [
                    ["type": "Split", "behavior": "Isolated", "invert": false, "pattern": ["Regex":
                        #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?[\p{L}\p{M}]+|\p{N}| ?[^\s\p{L}\p{M}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#]],
                    ["type": "ByteLevel", "add_prefix_space": false, "trim_offsets": false, "use_regex": false],
                ]]
                : ["type": "ByteLevel", "add_prefix_space": false, "trim_offsets": true, "use_regex": true]
            return [
                "added_tokens": added,
                "normalizer": family == .qwen ? ["type": "NFC"] : NSNull(),
                "pre_tokenizer": preTokenizer,
                "post_processor": ["type": "ByteLevel", "add_prefix_space": false, "trim_offsets": false, "use_regex": false],
                "decoder": ["type": "ByteLevel", "add_prefix_space": false, "trim_offsets": false, "use_regex": false],
                "model": ["type": "BPE", "vocab": vocab, "merges": merges, "byte_fallback": false],
            ]
        case .metaspace:
            var vocab: [String: Int] = ["<unk>": 0]
            for byte in 0..<256 { vocab[String(format: "<0x%02X>", byte)] = vocab.count }
            for character in "abcdefghijklmnopqrstuvwxyzHTW▁'.,!?-0123456789\n" { vocab[String(character)] = vocab.count }
            let merges = [["▁", "t"], ["h", "e"], ["▁t", "he"], ["i", "n"], ["▁", "w"], ["o", "r"], ["e", "r"],
                          ["\n", "\n"], ["▁", "▁"], ["1", "2"]]
            for merge in merges { vocab[merge.joined()] = vocab.count }
            return [
                "added_tokens": added,
                "normalizer": ["type": "Replace", "pattern": ["String": " "], "content": "▁"],
                "pre_tokenizer": ["type": "Split", "pattern": ["String": " "], "behavior": "MergedWithPrevious", "invert": false],
                "post_processor": [
                    "type": "TemplateProcessing",
                    "single": [["Sequence": ["id": "A", "type_id": 0]]],
                    "pair": [["Sequence": ["id": "A", "type_id": 0]], ["Sequence": ["id": "B", "type_id": 1]]],
                    "special_tokens": [:] as [String: Any],
                ],
                "decoder": ["type": "Sequence", "decoders": [
                    ["type": "Replace", "pattern": ["String": "▁"], "content": " "], ["type": "ByteFallback"], ["type": "Fuse"],
                ]],
                "model": ["type": "BPE", "vocab": vocab, "merges": merges, "byte_fallback": true, "unk_token": "<unk>"],
            ]
        }
    }

    /// GPT-2 `bytes_to_unicode`, in byte order.
    private static let byteLevelSymbols: [String] = {
        var printable = Array(33...126) + Array(161...172) + Array(174...255)
        var mapped = printable
        var extra = 0
        for byte in 0..<256 where !printable.contains(byte) {
            printable.append(byte)
            mapped.append(256 + extra)
            extra += 1
        }
        var symbols = Array(repeating: "", count: 256)
        for (byte, scalar) in zip(printable, mapped) { symbols[byte] = String(UnicodeScalar(UInt32(scalar))!) }
        return symbols
    }()

    private static func write(_ object: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }
}
