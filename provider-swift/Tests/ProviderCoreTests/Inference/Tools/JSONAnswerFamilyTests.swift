import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// Nemotron-shaped byte-level tokenizer: the pinned special and added tokens at
/// their ids below 1,000 (placeholders for the rest), GPT-2 single-byte
/// spellings at 1000...1255 and "x" for the other BPE ids up to 131,071. Its
/// template opens `<think>` unless thinking is off, as the shipped template does.
struct NemotronByteTestTokenizer: MLXLMCommon.Tokenizer {
    static let pinned: [(String, Int)] = [
        ("</s>", 2), ("<|im_start|>", 10), ("<|im_end|>", 11), ("<think>", 12), ("</think>", 13),
        ("<tool_call>", 14), ("</tool_call>", 15),
    ]
    static let firstByteID = 1000
    private static let byteSpelling: [UInt8: String] = {
        var spelling = [UInt8: String]()
        for value in UInt32(0)..<512 {
            let text = String(Character(Unicode.Scalar(value)!))
            if let bytes = ByteLevelBPE.bytes(text), bytes.count == 1 { spelling[bytes[0]] = text }
        }
        return spelling
    }()

    var markers = Self.pinned

    static func tokens(_ text: String, markers: [(String, Int)] = pinned) -> [Int] {
        let bytes = Array(text.utf8)
        var ids: [Int] = []
        var index = 0
        while index < bytes.count {
            if let marker = markers.first(where: { bytes[index...].starts(with: Array($0.0.utf8)) }) {
                ids.append(marker.1)
                index += marker.0.utf8.count
            } else {
                ids.append(firstByteID + Int(bytes[index]))
                index += 1
            }
        }
        return ids
    }

    static func prompt(thinking: Bool) -> String {
        "<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n" + (thinking ? "<think>\n" : "<think></think>")
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { Self.tokens(text, markers: markers) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        String(decoding: tokenIds.flatMap { id -> [UInt8] in
            if let marker = markers.first(where: { $0.1 == id }) { return Array(marker.0.utf8) }
            let byte = id - Self.firstByteID
            return (0...255).contains(byte) ? [UInt8(byte)] : Array("x".utf8)
        }, as: UTF8.self)
    }
    func convertTokenToId(_ token: String) -> Int? { markers.first { $0.0 == token }?.1 }
    func convertIdToToken(_ id: Int) -> String? {
        if let marker = markers.first(where: { $0.1 == id }) { return marker.0 }
        if id < Self.firstByteID { return id >= 0 ? "<SPECIAL_\(id)>" : nil }
        if id < Self.firstByteID + 256 { return Self.byteSpelling[UInt8(id - Self.firstByteID)] }
        return id < 131072 ? "x" : nil
    }
    var bosToken: String? { "<s>" }
    var eosToken: String? { "<|im_end|>" }
    var unknownToken: String? { "<unk>" }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] {
        Self.tokens(Self.prompt(thinking: additionalContext?["enable_thinking"] as? Bool != false))
    }
}

@Suite("JSON answer grammar: admitted families")
struct JSONAnswerFamilyTests {
    private typealias F = QwenAnswerFixture
    /// One handle per tokenizer, so each vocabulary is built once for the suite.
    private static let qwenHandle = TokenizerHandle(QwenByteTestTokenizer())
    private static let nemotronHandle = TokenizerHandle(NemotronByteTestTokenizer())
    private static let nemotronStops: Set<Int> = [2, 11]
    /// Rendered with thinking off, so output starts in the answer.
    private static let qwenPrompt = QwenByteTestTokenizer.tokens(QwenByteTestTokenizer.prompt(thinking: false))
    private static let nemotronPrompt = NemotronByteTestTokenizer.tokens(
        NemotronByteTestTokenizer.prompt(thinking: false))

    static let bonsaiIDs = ["ternary-bonsai-2-27b", "EigenLabs/Ternary-Bonsai-2-27B-MLX-2bit",
                            EngineV2SupportedModels.bonsai2ModelID]
    static let lightningIDs = ["nvidia-nemotron-3.5-lightning", EngineV2SupportedModels.nemotron35LightningModelID,
                               EngineV2SupportedModels.nemotron35LightningMTPModelID,
                               EngineV2SupportedModels.nemotron35LightningHybrid8BuildID,
                               EngineV2SupportedModels.nemotron35LightningRollback4bitBuildID]

    private func request(_ format: String, model: String) throws -> OpenAIChatCompletionRequest {
        var request = try F.request(format: format)
        request.model = model
        return request
    }

    private func make(_ request: OpenAIChatCompletionRequest, modelType: String, handle: TokenizerHandle,
                      prompt: [Int], stops: Set<Int>, pair: Bool = false,
                      families: JSONAnswerPolicy.Families = .all) -> JSONAnswerConstraint? {
        JSONAnswerPolicy.constraint(request: request, tokenizer: handle, modelID: request.model,
            modelType: modelType, defaultMaxTokens: 100, stopTokenIDs: stops, promptTokens: prompt,
            servesDistributedPair: pair, families: families)
    }

    /// Bonsai 27B's artifact stops at `<|im_end|>` alone; a slot that also
    /// stops at `<|endoftext|>` still ends the answer with `<|im_end|>`.
    @Test func bonsaiBuildsAnswerUnderTheQwenIDs() throws {
        for model in Self.bonsaiIDs {
            for stops: Set<Int> in [[F.imEnd], F.stops] {
                let constraint = try #require(make(request(F.schemaFormat(F.schema), model: model),
                    modelType: "prism_hadamard_qwen35", handle: Self.qwenHandle, prompt: Self.qwenPrompt,
                    stops: stops), "\(model) \(stops)")
                #expect(constraint.initialPhase == .answer && constraint.format.family == "Bonsai")
                #expect(constraint.maxTokens == 64 && constraint.fallbackTokenID == F.imEnd)
            }
        }
    }

    @Test func lightningAnswersUnderItsOwnContract() throws {
        for model in Self.lightningIDs {
            let constraint = try #require(make(request(F.jsonObject, model: model), modelType: "nemotron_h",
                handle: Self.nemotronHandle, prompt: Self.nemotronPrompt, stops: Self.nemotronStops), "\(model)")
            #expect(constraint.initialPhase == .answer && constraint.format.family == "Nemotron")
            #expect(constraint.fallbackTokenID == 11)
        }
    }

    /// Both new families constrain answer-first prompts only: a prompt that
    /// opens a thought stays prompt-only, as does any request on a cluster
    /// pair (which refuses token constraints). Qwen keeps both as before.
    @Test func reasoningFirstPromptsAndPairsStayPromptOnly() throws {
        let qwenThinking = QwenByteTestTokenizer.tokens(QwenByteTestTokenizer.prompt(thinking: true))
        let nemotronThinking = NemotronByteTestTokenizer.tokens(NemotronByteTestTokenizer.prompt(thinking: true))
        let bonsai = try request(F.jsonObject, model: "ternary-bonsai-2-27b")
        let lightning = try request(F.jsonObject, model: "nvidia-nemotron-3.5-lightning")
        #expect(make(bonsai, modelType: "prism_hadamard_qwen35", handle: Self.qwenHandle, prompt: qwenThinking,
            stops: F.stops) == nil)
        #expect(make(lightning, modelType: "nemotron_h", handle: Self.nemotronHandle, prompt: nemotronThinking,
            stops: Self.nemotronStops) == nil)
        #expect(make(bonsai, modelType: "prism_hadamard_qwen35", handle: Self.qwenHandle, prompt: Self.qwenPrompt,
            stops: F.stops, pair: true) == nil)
        #expect(make(lightning, modelType: "nemotron_h", handle: Self.nemotronHandle, prompt: Self.nemotronPrompt,
            stops: Self.nemotronStops, pair: true) == nil)
        let qwen = try request(F.jsonObject, model: "EigenLabs/Qwen3.8-27B-4bit-mtp")
        #expect(make(qwen, modelType: "qwen3_5", handle: Self.qwenHandle, prompt: qwenThinking,
            stops: F.stops)?.initialPhase == .reasoning)
        #expect(make(qwen, modelType: "qwen3_5", handle: Self.qwenHandle, prompt: Self.qwenPrompt,
            stops: F.stops, pair: true) != nil)
    }

    /// The slot's pair flag reaches the policy through the factory the text
    /// path calls (`MultiModelBatchSchedulerEngine.prepareCompletion`).
    @Test func theFactoryPassesThePairFlagThrough() throws {
        let cases: [(OpenAIChatCompletionRequest, String, TokenizerHandle, [Int], Set<Int>)] = [
            (try request(F.jsonObject, model: "ternary-bonsai-2-27b"), "prism_hadamard_qwen35", Self.qwenHandle,
             Self.qwenPrompt, F.stops),
            (try request(F.jsonObject, model: "nvidia-nemotron-3.5-lightning"), "nemotron_h", Self.nemotronHandle,
             Self.nemotronPrompt, Self.nemotronStops),
        ]
        for (request, modelType, handle, prompt, stops) in cases {
            for pair in [false, true] {
                let constraint = try ToolConstraintFactory.make(
                    prepared: ToolChoicePromptPolicy.prepare(request, modelType: modelType), request: request,
                    tokenizer: handle, modelContext: .init(modelId: request.model, modelType: modelType),
                    defaultMaxTokens: 100, stopTokenIDs: stops, nativePromptTokens: prompt,
                    servesDistributedPair: pair)
                #expect((constraint is JSONAnswerConstraint) == !pair, "\(request.model) pair \(pair)")
            }
        }
    }

    /// A shared `model_type` admits only the listed builds: not the Bonsai 2
    /// 9B, which drafts, nor Nano or Super.
    @Test func unlistedBuildsOfAnAdmittedTypeStayPromptOnly() throws {
        for model in [Bonsai9BModelPolicy.modelID, Bonsai9BModelPolicy.eigenModelID,
                      "PrismML/Some-Other-Hadamard-Qwen", "EigenLabs/Qwen3.5-9B-MLX-4bit-mtp"] {
            #expect(make(try request(F.jsonObject, model: model), modelType: "prism_hadamard_qwen35",
                handle: Self.qwenHandle, prompt: Self.qwenPrompt, stops: F.stops) == nil, "\(model)")
        }
        for model in ["nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B", "nvidia-nemotron-3.5-super"] {
            #expect(make(try request(F.jsonObject, model: model), modelType: "nemotron_h", handle: Self.nemotronHandle,
                prompt: Self.nemotronPrompt, stops: Self.nemotronStops) == nil, "\(model)")
        }
    }

    /// The switch's `qwen` value keeps the grammar to the Qwen types, which
    /// are admitted under either value.
    @Test func theQwenOnlySwitchAdmitsOnlyTheQwenTypes() throws {
        #expect(make(try request(F.jsonObject, model: "ternary-bonsai-2-27b"), modelType: "prism_hadamard_qwen35",
            handle: Self.qwenHandle, prompt: Self.qwenPrompt, stops: F.stops, families: .qwenOnly) == nil)
        #expect(make(try request(F.jsonObject, model: "nvidia-nemotron-3.5-lightning"), modelType: "nemotron_h",
            handle: Self.nemotronHandle, prompt: Self.nemotronPrompt, stops: Self.nemotronStops,
            families: .qwenOnly) == nil)
        for families in [JSONAnswerPolicy.Families.all, .qwenOnly] {
            #expect(make(try request(F.jsonObject, model: "EigenLabs/Qwen3.8-27B-4bit-mtp"), modelType: "qwen3_5",
                handle: Self.qwenHandle, prompt: Self.qwenPrompt, stops: F.stops, families: families)?.format.family
                == "Qwen")
        }
        for value in [" Qwen ", "qwen", "0", "off", "FALSE", "no", "none"] {
            #expect(JSONAnswerPolicy.Families(environmentValue: value) == .qwenOnly, "\(value)")
        }
        for value in [nil, "", "all", "1", "on", "bonsai"] as [String?] {
            #expect(JSONAnswerPolicy.Families(environmentValue: value) == .all, "\(value ?? "unset")")
        }
    }

    /// The Lightning stop set must hold both answer terminators (Bonsai's
    /// `<|im_end|>`), and a tokenizer that moves a pinned marker is not
    /// constrained.
    @Test func aMismatchedNemotronContractStaysPromptOnly() throws {
        let request = try request(F.jsonObject, model: "nvidia-nemotron-3.5-lightning")
        #expect(make(request, modelType: "nemotron_h", handle: Self.nemotronHandle, prompt: Self.nemotronPrompt,
            stops: [11]) == nil)
        let moved = NemotronByteTestTokenizer.pinned.map { $0.0 == "</think>" ? ($0.0, 16) : $0 }
        #expect(make(request, modelType: "nemotron_h",
            handle: TokenizerHandle(NemotronByteTestTokenizer(markers: moved)), prompt: Self.nemotronPrompt,
            stops: Self.nemotronStops) == nil)
        #expect(make(try self.request(F.jsonObject, model: "ternary-bonsai-2-27b"), modelType: "prism_hadamard_qwen35",
            handle: Self.qwenHandle, prompt: Self.qwenPrompt, stops: [F.endOfText]) == nil)
    }

    /// Ids below 1,000 are special or added tokens: only the think markers are
    /// pieces, so `<|im_start|>`, `<tool_call>` and placeholders are never
    /// sampled, and the answer ends with `<|im_end|>` or `</s>` once complete.
    /// Lightning is constrained from the answer phase only.
    @Test func theNemotronVocabularyAdmitsOnlyItsBytePiecesAndMarkers() throws {
        let profile = JSONAnswerProfile.nemotron35
        let vocabulary = try JSONAnswerVocabulary(tokenizer: NemotronByteTestTokenizer(), profile: profile,
            stopTokenIDs: Self.nemotronStops)
        #expect(vocabulary.answerEOS == [2, 11] && vocabulary.fallbackTokenID == 11)
        #expect(vocabulary.pieces[12] == Array("<think>".utf8) && vocabulary.pieces[13] == Array("</think>".utf8))
        for id in [0, 1, 3, 10, 14, 15, 999] { #expect(vocabulary.pieces[id].isEmpty, "\(id)") }
        #expect(vocabulary.pieces[1000 + 0x7B] == [0x7B])
        let format = try JSONAnswerFormat(.jsonObject(), forbidding: profile.contentMarkers, family: profile.family)
        let constraint = try JSONAnswerConstraint(format: format, profile: profile, vocabulary: vocabulary,
            initialPhase: .answer, maxTokens: 256)
        func walk(_ text: String) throws -> Int {
            var state = constraint.initialState
            for token in Self.nemotronBytes(text) {
                #expect(!constraint.allowedTokenIDs(state: state, remainingTokens: 10).contains(where: {
                    [0, 1, 10, 12, 13, 14, 15].contains($0) }))
                state = try #require(constraint.nextState(state: state, tokenID: token), "token \(token)")
            }
            return state
        }
        let complete = try walk("{\"a\": [1, \"x\"]}")
        #expect(constraint.nextState(state: complete, tokenID: 11) == -1)
        #expect(constraint.nextState(state: complete, tokenID: 2) == -1)
        // The answer may not spell a framing marker, even inside a string.
        #expect(constraint.nextState(state: try walk("{\"a\": \"<tool_call"),
            tokenID: 1000 + Int(UInt8(ascii: ">"))) == nil)
        #expect(constraint.nextState(state: try walk("{\"a\": \"<|im_end|"),
            tokenID: 1000 + Int(UInt8(ascii: ">"))) == nil)
        // `</s>` (id 2) ends only a complete answer, but its spelling, an HTML
        // close tag, has no marker and stays writable byte by byte.
        let open = try walk("{\"a\": \"<s>gone")
        #expect(constraint.nextState(state: open, tokenID: 2) == nil)
        #expect(constraint.nextState(state: try walk("{\"a\": \"<s>gone</s>\"}"), tokenID: 11) == -1)
    }

    /// Single-byte ids of `text`, never a marker id: the spelling the answer
    /// writes, not what the tokenizer would merge it into.
    private static func nemotronBytes(_ text: String) -> [Int] {
        text.utf8.map { NemotronByteTestTokenizer.firstByteID + Int($0) }
    }
}

#if DEBUG
/// The scheduler's forwarding body with the routing flags production passes
/// for each family (`MultiModelBatchSchedulerEngine.prepareCompletion`): an
/// answer-first constrained row streams its JSON as content, and an answer
/// that misses is the typed 422 under the family's name.
@Suite("JSON answer grammar: Bonsai and Lightning serving")
struct JSONAnswerFamilyServingTests {
    private typealias F = QwenAnswerFixture

    private func run(model: String, modelType: String, profile: JSONAnswerProfile, output: [String],
                     finish: String = "stop") async throws -> QwenAnswerOutcome {
        var request = try F.request(format: F.schemaFormat(F.schema))
        request.model = model
        let context = ChatTemplateFixContext(modelId: model, modelType: modelType)
        let answer = try JSONAnswerFormat(try #require(request.responseFormat), forbidding: profile.contentMarkers,
                                          family: profile.family)
        let upstream = AsyncStream<GenerationEvent> { continuation in
            for chunk in output { continuation.yield(.chunk(chunk)) }
            continuation.yield(.info(promptTokens: 1, completionTokens: output.count, tokensPerSecond: 0,
                finishReason: finish))
            continuation.finish()
        }
        let stream = try MultiModelBatchSchedulerEngine(registryProvider: { [:] })._testMakeEventStream(
            upstream: upstream, cancelUpstream: {},
            prepared: ToolChoicePromptPolicy.prepare(request, modelType: modelType),
            releaseBox: OneShotRelease(release: { _ in }, modelId: "fixture"),
            nativeReasoningPrefix: "<think></think>",
            preserveInnerReasoningSpans: ToolChoiceEnforcementPolicy.preservesInnerReasoningSpans(context),
            absorbStrayThinkClose: ToolChoiceEnforcementPolicy.absorbsStrayThinkClose(context),
            answerFormat: answer)
        var outcome = QwenAnswerOutcome()
        do {
            for try await event in stream { outcome.record(event) }
        } catch { outcome.error = error }
        outcome.finish()
        return outcome
    }

    @Test(arguments: [("ternary-bonsai-2-27b", "prism_hadamard_qwen35", "Bonsai"),
                      ("nvidia-nemotron-3.5-lightning", "nemotron_h", "Nemotron")])
    func answersStreamAsContentAndMissesAreTyped422s(model: String, modelType: String, family: String) async throws {
        let profile: JSONAnswerProfile = family == "Bonsai" ? .bonsai2 : .nemotron35
        let valid = try await run(model: model, modelType: modelType, profile: profile,
            output: [#"{"tables_used":["a"],"#, #""count":3}"#])
        #expect(valid.error == nil && valid.reasoning.isEmpty)
        #expect(valid.content == #"{"tables_used":["a"],"count":3}"#)
        let miss = try await run(model: model, modelType: modelType, profile: profile,
            output: [#"{"tables_used":["PRIVATE"]}"#])
        guard case .invalidResponseFormatOutput(let message)? = miss.error as? MLXOpenAIServiceError else {
            Issue.record("unexpected \(String(describing: miss.error))"); return
        }
        #expect(message.hasPrefix(family + " ") && !message.contains("PRIVATE"))
        #expect(miss.error.map { ProviderLoop.mapInferenceErrorToStatus($0) } == 422)
    }
}
#endif

/// The opt-in real-tokenizer checks below read tokenizer, template and config
/// files only (no weights). The stop set is the one the slot gets: the
/// artifact's EOS (`ModelEOSPolicy`) plus the tokenizer's.
enum JSONAnswerRealTokenizerCheck {
    static func load(_ key: String) async throws -> (any MLXLMCommon.Tokenizer, Set<Int>) {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment[key]))
        let tokenizer = try await LocalTokenizerLoader(environment: [:]).load(from: directory)
        var stops = try #require(ModelEOSPolicy.artifactEOSTokenIds(modelDirectory: directory))
        if let eos = tokenizer.eosToken.flatMap(tokenizer.convertTokenToId) { stops.insert(eos) }
        return (tokenizer, stops)
    }

    /// The pinned contract, both rendered JSON prompt tails, and a real
    /// tokenization of an answer that ends at `end`.
    static func check(_ tokenizer: any MLXLMCommon.Tokenizer, stops: Set<Int>, profile: JSONAnswerProfile,
                      pieceCount: Int, end: Int) throws {
        let vocabulary = try JSONAnswerVocabulary(tokenizer: tokenizer, profile: profile, stopTokenIDs: stops)
        #expect(vocabulary.pieceTokenIDs.count == pieceCount)
        for (thinking, phase) in [(false, JSONAnswerPhase.answer), (true, .reasoning)] {
            let tokens = try tokenizer.applyChatTemplate(messages: [["role": "user", "content": "Extract the name."]],
                tools: nil, additionalContext: ["enable_thinking": thinking])
            let tail = tokenizer.decode(tokenIds: Array(tokens.suffix(ReasoningPromptProbe.tailTokenCount)),
                skipSpecialTokens: false)
            #expect(profile.initialPhase(promptTail: tail) == phase)
        }
        let answer = try JSONAnswerFormat(.jsonObject(), forbidding: profile.contentMarkers, family: profile.family)
        let constraint = try JSONAnswerConstraint(format: answer, profile: profile, vocabulary: vocabulary,
            initialPhase: .answer, maxTokens: 256)
        var state = constraint.initialState
        for token in tokenizer.encode(text: "{\"name\": \"Ada Lovelace\", \"born\": 1815, \"tags\": [\"é\", null]}",
                                      addSpecialTokens: false) {
            state = try #require(constraint.nextState(state: state, tokenID: token), "token \(token)")
        }
        #expect(constraint.nextState(state: state, tokenID: end) == -1)
    }
}

/// `DARKBLOOM_TEST_BONSAI_TOKENIZER_DIR=<Bonsai 2 27B snapshot>`.
@Suite("Bonsai JSON answer real tokenizer",
       .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_BONSAI_TOKENIZER_DIR"] != nil))
struct BonsaiJSONAnswerRealTokenizerTests {
    @Test func theShippedTokenizerMatchesThePinnedContract() async throws {
        let (tokenizer, stops) = try await JSONAnswerRealTokenizerCheck.load("DARKBLOOM_TEST_BONSAI_TOKENIZER_DIR")
        #expect(stops.contains(248_046))
        try JSONAnswerRealTokenizerCheck.check(tokenizer, stops: stops, profile: .bonsai2, pieceCount: 248_044 + 2,
                                               end: 248_046)
    }
}

/// `DARKBLOOM_TEST_NEMOTRON_TOKENIZER_DIR=<Nemotron 3.5 Lightning snapshot>`.
@Suite("Nemotron JSON answer real tokenizer",
       .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_NEMOTRON_TOKENIZER_DIR"] != nil))
struct NemotronJSONAnswerRealTokenizerTests {
    @Test func theShippedTokenizerMatchesThePinnedContract() async throws {
        let (tokenizer, stops) = try await JSONAnswerRealTokenizerCheck.load("DARKBLOOM_TEST_NEMOTRON_TOKENIZER_DIR")
        #expect(stops == [2, 11])
        try JSONAnswerRealTokenizerCheck.check(tokenizer, stops: stops, profile: .nemotron35,
                                               pieceCount: 131_072 - 1_000 + 2, end: 11)
    }
}
