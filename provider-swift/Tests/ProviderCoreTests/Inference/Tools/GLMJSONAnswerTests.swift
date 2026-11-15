import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// GLM-5.3-Flash-shaped byte-level tokenizer: GPT-2 single-byte spellings at
/// ids 0...255, "x" for the other BPE ids below 154,820, and the added tokens
/// at their GLM ids. Its template ends at `<|assistant|>` with an open thought,
/// or a closed one when thinking is off.
struct GLMByteTestTokenizer: MLXLMCommon.Tokenizer {
    static let pinned: [(String, Int)] = [
        ("<|endoftext|>", 154820), ("[gMASK]", 154822), ("<sop>", 154824), ("<|system|>", 154826),
        ("<|user|>", 154827), ("<|assistant|>", 154828), ("<|observation|>", 154829), ("<think>", 154841),
        ("</think>", 154842), ("<tool_call>", 154843), ("</tool_call>", 154844), ("<arg_key>", 154847),
        ("</arg_key>", 154848), ("<arg_value>", 154849), ("</arg_value>", 154850),
    ]
    static let endOfText = 154820, user = 154827, assistant = 154828, observation = 154829
    static let think = 154841, thinkClose = 154842, toolCall = 154843
    static let stops: Set<Int> = [endOfText, user, observation]
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
                ids.append(Int(bytes[index]))
                index += 1
            }
        }
        return ids
    }

    static func prompt(thinking: Bool) -> String {
        "[gMASK]<sop><|user|>hi<|assistant|>" + (thinking ? "<think>" : "<think></think>")
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { Self.tokens(text, markers: markers) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        String(decoding: tokenIds.flatMap { id -> [UInt8] in
            if let marker = markers.first(where: { $0.1 == id }) { return Array(marker.0.utf8) }
            return id < 256 ? [UInt8(id)] : Array("x".utf8)
        }, as: UTF8.self)
    }
    func convertTokenToId(_ token: String) -> Int? { markers.first { $0.0 == token }?.1 }
    func convertIdToToken(_ id: Int) -> String? {
        if let marker = markers.first(where: { $0.1 == id }) { return marker.0 }
        if id < 256 { return id >= 0 ? Self.byteSpelling[UInt8(id)] : nil }
        if id < 154820 { return "x" }
        return id < 154856 ? "<|reserved_\(id)|>" : nil
    }
    var bosToken: String? { nil }
    var eosToken: String? { "<|endoftext|>" }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] {
        Self.tokens(Self.prompt(thinking: additionalContext?["enable_thinking"] as? Bool != false))
    }
}

@Suite("JSON answer grammar: GLM-5.3-Flash")
struct GLMJSONAnswerTests {
    private typealias F = QwenAnswerFixture
    private typealias T = GLMByteTestTokenizer
    private static let handle = TokenizerHandle(GLMByteTestTokenizer())
    private static let thinkingPrompt = T.tokens(T.prompt(thinking: true))
    private static let answerPrompt = T.tokens(T.prompt(thinking: false))

    private func request(_ format: String?, tools: String? = nil,
                         image: Bool = false) throws -> OpenAIChatCompletionRequest {
        var request = try F.request(format: format, tools: tools, image: image)
        request.model = "glm-5.3-flash"
        return request
    }

    private func make(_ request: OpenAIChatCompletionRequest, tokenizer: TokenizerHandle = handle,
                      prompt: [Int] = thinkingPrompt, stops: Set<Int> = T.stops, accepts: Bool = true,
                      pair: Bool = false, glm: Bool = true) -> JSONAnswerConstraint? {
        JSONAnswerPolicy.constraint(request: request, tokenizer: tokenizer, modelID: request.model,
            modelType: "glm5_next", defaultMaxTokens: 100, stopTokenIDs: stops, promptTokens: prompt,
            servesDistributedPair: pair, acceptsTokenConstraints: accepts, glm: glm)
    }

    /// GLM's JSON prompts open a thought by default: the answer is constrained
    /// from the reasoning on; a thinking-off prompt starts in the answer.
    @Test func glmAnswersUnderItsOwnContract() throws {
        for format in [F.jsonObject, F.schemaFormat(F.schema)] {
            let thinking = try #require(make(try request(format)), "\(format)")
            #expect(thinking.initialPhase == .reasoning && thinking.format.family == "GLM")
            #expect(thinking.maxTokens == 64 && thinking.fallbackTokenID == T.user)
            #expect(thinking.channelPrefix == "<think>")
            let answerFirst = try #require(make(try request(format), prompt: Self.answerPrompt))
            #expect(answerFirst.initialPhase == .answer && answerFirst.channelPrefix == "<think></think>")
        }
    }

    /// Without the switch, on an engine that runs no token constraint (a
    /// cluster pair, or a native profile without the qualification), or for a
    /// request the grammar does not cover, GLM keeps today's prompt-only answer
    /// and its check: never a new refusal.
    @Test func glmStaysPromptOnlyWhereTheGrammarCannotRun() throws {
        let json = try request(F.jsonObject)
        #expect(make(json, glm: false) == nil)
        #expect(make(json, accepts: false) == nil)
        #expect(make(json, accepts: false, pair: true) == nil)
        #expect(make(try request(nil)) == nil)
        #expect(make(try request(#"{"type":"text"}"#)) == nil)
        #expect(make(try request(F.jsonObject, tools: F.tools)) == nil)
        #expect(make(try request(F.jsonObject, image: true)) == nil)
        // A slot whose stop set lacks an answer terminator, or a tokenizer that
        // moves a pinned marker, is not constrained.
        #expect(make(json, stops: [T.endOfText]) == nil)
        let moved = T.pinned.map { $0.0 == "</think>" ? ($0.0, 154_851) : $0 }
        #expect(make(json, tokenizer: TokenizerHandle(GLMByteTestTokenizer(markers: moved))) == nil)
    }

    /// The slot's flag reaches the policy through the factory the text path
    /// calls (`MultiModelBatchSchedulerEngine`), so an engine that refuses
    /// constraints never receives one.
    @Test func theFactoryPassesTheEngineFlagThrough() throws {
        let json = try request(F.jsonObject)
        for accepts in [false, true] {
            for glm in [false, true] {
                let constraint = try ToolConstraintFactory.make(
                    prepared: ToolChoicePromptPolicy.prepare(json, modelType: "glm5_next"), request: json,
                    tokenizer: Self.handle, modelContext: .init(modelId: json.model, modelType: "glm5_next"),
                    defaultMaxTokens: 100, stopTokenIDs: T.stops, nativePromptTokens: Self.thinkingPrompt,
                    acceptsTokenConstraints: accepts, glmJSONAnswers: glm)
                #expect((constraint is JSONAnswerConstraint) == (accepts && glm), "accepts \(accepts) glm \(glm)")
            }
        }
    }

    /// Reasoning is free text that cannot end the request or spell a turn
    /// marker; `</think>` opens the answer, which is one JSON value of the
    /// schema and ends with `<|user|>` or `<|endoftext|>` once complete.
    @Test func theGLMVocabularyAdmitsOnlyItsBytePiecesAndMarkers() throws {
        let profile = JSONAnswerProfile.glm5Next
        let vocabulary = try JSONAnswerVocabulary(tokenizer: GLMByteTestTokenizer(), profile: profile,
            stopTokenIDs: T.stops)
        #expect(vocabulary.answerEOS == [T.endOfText, T.user] && vocabulary.fallbackTokenID == T.user)
        #expect(vocabulary.pieces[T.think] == Array("<think>".utf8))
        #expect(vocabulary.pieces[T.thinkClose] == Array("</think>".utf8))
        for id in [T.endOfText, 154822, T.user, T.assistant, T.observation, T.toolCall, 154855, 154879] {
            #expect(vocabulary.pieces[id].isEmpty, "\(id)")
        }
        let constraint = try JSONAnswerConstraint(format: try F.answerFormatGLM(F.schemaFormat(F.schema)),
            profile: profile, vocabulary: vocabulary, initialPhase: .reasoning, maxTokens: 512)
        func walk(_ text: String, from start: Int? = nil) throws -> Int {
            var state = start ?? constraint.initialState
            for token in T.tokens(text) {
                let allowed = constraint.allowedTokenIDs(state: state, remainingTokens: 400)
                #expect(allowed.contains(token), "token \(token)")
                #expect(!allowed.contains(where: { [T.user, T.endOfText, T.observation, T.assistant].contains($0) }))
                state = try #require(constraint.nextState(state: state, tokenID: token), "token \(token)")
            }
            return state
        }
        let answer = try walk("Count the tables.</think>")
        let complete = try walk(#"{"tables_used":["a"],"count":2}"#, from: answer)
        #expect(constraint.nextState(state: complete, tokenID: T.user) == -1)
        #expect(constraint.nextState(state: complete, tokenID: T.endOfText) == -1)
        // `<|observation|>` stops the engine but is not an answer terminator.
        #expect(!constraint.allowedTokenIDs(state: complete, remainingTokens: 10).contains(T.observation))
        // A missing required key or an unknown key cannot be sampled.
        let open = try walk(#"{"tables_used":["a"]"#, from: answer)
        #expect(constraint.nextState(state: open, tokenID: Int(UInt8(ascii: "}"))) == nil)
        #expect(constraint.nextState(state: try walk(#"{"#, from: answer), tokenID: Int(UInt8(ascii: "\"")))
            != nil)
        #expect(constraint.nextState(state: try walk(#"{""#, from: answer), tokenID: Int(UInt8(ascii: "z"))) == nil)
        // Reasoning cannot spell a turn marker byte by byte.
        let spelled = try walk("Plan <|user|")
        #expect(constraint.nextState(state: spelled, tokenID: Int(UInt8(ascii: ">"))) == nil)
    }

    @Test func theSwitchIsOnOnlyWhenSetOn() {
        for value in ["1", "on", " ON ", "true", "yes"] {
            #expect(JSONAnswerPolicy.glmEnabled(environmentValue: value), "\(value)")
        }
        for value in [nil, "", "0", "off", "false", "no", "maybe"] as [String?] {
            #expect(!JSONAnswerPolicy.glmEnabled(environmentValue: value), "\(value ?? "unset")")
        }
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(JSONAnswerPolicy.glmEnvironmentKey))
    }
}

#if DEBUG
/// The scheduler's forwarding body as production runs an admitted GLM JSON
/// request: the native split seeded from the open thought
/// (`JSONAnswerConstraint.channelPrefix`), the format the grammar compiled
/// (`JSONAnswerOutput`) and GLM's withheld answer and its check.
@Suite("JSON answer grammar: GLM serving")
struct GLMJSONAnswerServingTests {
    private typealias F = QwenAnswerFixture

    private func run(_ output: [String], finish: String = "stop") async throws -> QwenAnswerOutcome {
        var request = try F.request(format: F.schemaFormat(F.schema))
        request.model = "glm-5.3-flash"
        let profile = JSONAnswerProfile.glm5Next
        let answer = try JSONAnswerFormat(try #require(request.responseFormat), forbidding: profile.contentMarkers,
                                          family: profile.family)
        var prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "glm5_next")
        prepared.cutAnswersEndAtLength = true
        #expect(prepared.glmResponseFormat != nil)
        let upstream = AsyncStream<GenerationEvent> { continuation in
            for chunk in output { continuation.yield(.chunk(chunk)) }
            continuation.yield(.info(promptTokens: 1, completionTokens: output.count, tokensPerSecond: 0,
                finishReason: finish))
            continuation.finish()
        }
        let stream = try MultiModelBatchSchedulerEngine(registryProvider: { [:] })._testMakeEventStream(
            upstream: upstream, cancelUpstream: {}, prepared: prepared,
            releaseBox: OneShotRelease(release: { _ in }, modelId: "fixture"),
            nativeReasoningPrefix: "<think>", recordsWithheldOutput: true, answerFormat: answer)
        var outcome = QwenAnswerOutcome()
        do {
            for try await event in stream { outcome.record(event) }
        } catch { outcome.error = error }
        outcome.finish()
        return outcome
    }

    @Test func theAnswerLeavesAfterTheReasoningAndAMissIsATyped422() async throws {
        let valid = try await run(["Count the tables.", "</think>", #"{"tables_used":["a"],"#, #""count":3}"#])
        #expect(valid.error == nil && valid.reasoning == "Count the tables.")
        // The withheld answer leaves once, whole, at the end.
        #expect(valid.content == #"{"tables_used":["a"],"count":3}"# && valid.contentDeltas.count == 1)
        let miss = try await run(["Plan.", "</think>", #"{"tables_used":["PRIVATE"]}"#])
        guard case .invalidResponseFormatOutput(let message)? = miss.error as? MLXOpenAIServiceError else {
            Issue.record("unexpected \(String(describing: miss.error))"); return
        }
        #expect(message.hasPrefix("GLM ") && !message.contains("PRIVATE") && miss.content.isEmpty)
    }

    /// A cut at the token limit ends as `length` with the answer as generated,
    /// as for every family (`TokenLimitCutPolicy`).
    @Test func anAnswerCutAtTheLimitLeavesAsGenerated() async throws {
        let cut = try await run(["Plan.", "</think>", #"{"tables_used":["a"],"co"#], finish: "length")
        #expect(cut.error == nil && cut.info?.stopReason == "length")
        #expect(cut.content == #"{"tables_used":["a"],"co"#)
    }
}
#endif

extension QwenAnswerFixture {
    static func answerFormatGLM(_ format: String) throws -> JSONAnswerFormat {
        let responseFormat = try #require(try request(format: format).responseFormat)
        let profile = JSONAnswerProfile.glm5Next
        return try JSONAnswerFormat(responseFormat, forbidding: profile.contentMarkers, family: profile.family)
    }
}

/// `DARKBLOOM_TEST_GLM_TOKENIZER_DIR=<GLM-5.3-Flash snapshot>`. GLM's template
/// ends every generation prompt with an open thought, so a JSON prompt starts
/// in reasoning (the shared check also expects a thinking-off answer phase).
@Suite("GLM JSON answer real tokenizer",
       .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM_TOKENIZER_DIR"] != nil))
struct GLMJSONAnswerRealTokenizerTests {
    @Test func theShippedTokenizerMatchesThePinnedContract() async throws {
        let (tokenizer, stops) = try await JSONAnswerRealTokenizerCheck.load("DARKBLOOM_TEST_GLM_TOKENIZER_DIR")
        #expect(stops.isSuperset(of: [154_820, 154_827]))
        let profile = JSONAnswerProfile.glm5Next
        let vocabulary = try JSONAnswerVocabulary(tokenizer: tokenizer, profile: profile, stopTokenIDs: stops)
        #expect(vocabulary.pieceTokenIDs.count == 154_820 + 2)
        let prompt = try tokenizer.applyChatTemplate(messages: [["role": "user", "content": "Extract the name."]],
            tools: nil, additionalContext: nil)
        let tail = tokenizer.decode(tokenIds: Array(prompt.suffix(ReasoningPromptProbe.tailTokenCount)),
            skipSpecialTokens: false)
        #expect(profile.initialPhase(promptTail: tail) == .reasoning)
        let answer = try JSONAnswerFormat(.jsonObject(), forbidding: profile.contentMarkers, family: profile.family)
        let constraint = try JSONAnswerConstraint(format: answer, profile: profile, vocabulary: vocabulary,
            initialPhase: .reasoning, maxTokens: 256)
        var state = constraint.initialState
        for token in tokenizer.encode(text: "Find the name.</think>{\"name\": \"Ada Lovelace\", \"born\": 1815, "
                                      + "\"tags\": [\"é\", null]}", addSpecialTokens: false) {
            state = try #require(constraint.nextState(state: state, tokenID: token), "token \(token)")
        }
        #expect(constraint.nextState(state: state, tokenID: 154_827) == -1)
    }
}
