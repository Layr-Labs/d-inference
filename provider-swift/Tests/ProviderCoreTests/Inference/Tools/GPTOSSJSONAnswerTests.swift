import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// GPT-OSS-shaped byte-level tokenizer: GPT-2 single-byte spellings at ids
/// 0...255, "x" for the other base ids, the Harmony control tokens at their
/// o200k ids and nothing else. Every text byte is its own token.
struct GPTOSSAnswerByteTokenizer: MLXLMCommon.Tokenizer {
    static let controls: [(String, Int)] = [
        ("<|startoftext|>", 199998), ("<|endoftext|>", 199999), ("<|return|>", 200002), ("<|constrain|>", 200003),
        ("<|channel|>", 200005), ("<|start|>", 200006), ("<|end|>", 200007), ("<|message|>", 200008),
        ("<|call|>", 200012), ("<|endofprompt|>", 200018),
    ]
    static let endOfText = 199999, returnToken = 200002, channel = 200005, start = 200006, end = 200007
    static let message = 200008, call = 200012
    static let stops: Set<Int> = [endOfText, returnToken, call]
    private static let byteSpelling: [UInt8: String] = {
        var spelling = [UInt8: String]()
        for value in UInt32(0)..<512 {
            let text = String(Character(Unicode.Scalar(value)!))
            if let bytes = ByteLevelBPE.bytes(text), bytes.count == 1 { spelling[bytes[0]] = text }
        }
        return spelling
    }()

    var controls = Self.controls

    static func tokens(_ text: String, controls: [(String, Int)] = controls) -> [Int] {
        let bytes = Array(text.utf8)
        var ids: [Int] = []
        var index = 0
        while index < bytes.count {
            if let control = controls.first(where: { bytes[index...].starts(with: Array($0.0.utf8)) }) {
                ids.append(control.1)
                index += control.0.utf8.count
            } else {
                ids.append(Int(bytes[index]))
                index += 1
            }
        }
        return ids
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { Self.tokens(text, controls: controls) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        String(decoding: tokenIds.flatMap { id -> [UInt8] in
            if let control = controls.first(where: { $0.1 == id }) { return Array(control.0.utf8) }
            return id < 256 ? [UInt8(id)] : Array("x".utf8)
        }, as: UTF8.self)
    }
    func convertTokenToId(_ token: String) -> Int? { controls.first { $0.0 == token }?.1 }
    func convertIdToToken(_ id: Int) -> String? {
        if let control = controls.first(where: { $0.1 == id }) { return control.0 }
        if id < 256 { return Self.byteSpelling[UInt8(id)] }
        return id < 199998 ? "x" : nil
    }
    var bosToken: String? { nil }
    var eosToken: String? { "<|return|>" }
    var unknownToken: String? { nil }
    /// A rendered prompt: it ends at the assistant boundary, as Harmony's does.
    static let prompt = tokens("<|start|>user<|message|>hi<|end|><|start|>assistant")

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] { Self.prompt }
}

enum GPTOSSAnswerFixture {
    typealias T = GPTOSSAnswerByteTokenizer

    static var schema: [String: Any] { [
        "type": "object",
        "properties": [
            "sentiment": ["type": "string", "enum": ["positive", "negative"]],
            "score": ["type": "integer"],
        ] as [String: Any],
        "required": ["sentiment", "score"],
        "additionalProperties": false,
    ] }

    static func request(format: [String: Any]? = ["type": "json_object"], tools: [[String: Any]]? = nil,
                        choice: Any? = nil, stop: [String]? = nil, maxTokens: Int? = 64) throws
        -> OpenAIChatCompletionRequest {
        var body: [String: Any] = [
            "model": "gpt-oss-20b",
            "messages": [["role": "user", "content": "Classify: great phone."]],
        ]
        if let format { body["response_format"] = format }
        if let tools { body["tools"] = tools }
        if let choice { body["tool_choice"] = choice }
        if let stop { body["stop"] = stop }
        if let maxTokens { body["max_tokens"] = maxTokens }
        return try ProviderLoop.decodeOpenAIRequest(JSONSerialization.data(withJSONObject: body), modelType: "gpt_oss")
    }

    static func schemaFormat(_ schema: [String: Any] = schema, strict: Bool = true) -> [String: Any] {
        ["type": "json_schema", "json_schema": ["name": "label", "strict": strict, "schema": schema] as [String: Any]]
    }

    static func vocabulary() throws -> JSONAnswerVocabulary {
        var pieces = [[UInt8]](repeating: [], count: JSONAnswerProfile.gptOSSAnswer.vocabularySize)
        for byte in 0...255 { pieces[byte] = [UInt8(byte)] }
        return try JSONAnswerVocabulary(pieces: pieces, profile: .gptOSSAnswer, stopTokenIDs: T.stops)
    }

    static func constraint(_ format: [String: Any] = ["type": "json_object"], maxTokens: Int = 4_096) throws
        -> GPTOSSJSONAnswerConstraint {
        let request = try request(format: format)
        let answer = try JSONAnswerFormat(#require(request.responseFormat),
            forbidding: JSONAnswerProfile.gptOSSAnswer.contentMarkers, family: "GPT-OSS")
        return try GPTOSSJSONAnswerConstraint(format: answer, tokenizer: T(), vocabulary: vocabulary(),
            maxTokens: maxTokens)
    }

    static func analysis(_ reasoning: String) -> String {
        "<|channel|>analysis<|message|>" + reasoning + "<|end|>"
    }

    static let answerHeader = "<|start|>assistant<|channel|>final<|message|>"

    /// Feeds `text` through the constraint as the sampler would: each token
    /// must be allowed at its budget before it is confirmed. Returns the final
    /// state (-1 after `<|return|>`), or nil at the first token refused.
    static func walk(_ text: String, _ constraint: GPTOSSJSONAnswerConstraint, from initial: Int = 0,
                     consumed: Int = 0) -> Int? {
        var state = initial
        for (offset, token) in T.tokens(text).enumerated() {
            let remaining = constraint.maxTokens - consumed - offset
            guard state >= 0, constraint.allowedTokenIDs(state: state, remainingTokens: remaining).contains(token),
                  let next = constraint.nextState(state: state, tokenID: token) else { return nil }
            state = next
        }
        return state
    }
}

@Suite("GPT-OSS JSON answers")
struct GPTOSSJSONAnswerTests {
    typealias F = GPTOSSAnswerFixture
    typealias T = GPTOSSAnswerByteTokenizer

    // MARK: - The constraint

    @Test("the answer follows the analysis under the plain final header and ends at its value")
    func answerFollowsTheAnalysis() throws {
        let constraint = try F.constraint()
        #expect(constraint.allowedTokenIDs(state: 0, remainingTokens: 100) == [T.channel])
        let afterAnalysis = try #require(F.walk(F.analysis("Plan."), constraint))
        // After the analysis only the plain answer header can be written.
        #expect(constraint.allowedTokenIDs(state: afterAnalysis, remainingTokens: 100) == [T.start])
        let inAnswer = try #require(F.walk(F.answerHeader + "{\"a\":[1,true,null]}", constraint, from: afterAnalysis))
        #expect(constraint.allowedTokenIDs(state: inAnswer, remainingTokens: 100).contains(T.returnToken))
        #expect(constraint.nextState(state: inAnswer, tokenID: T.returnToken) == -1)
        #expect(F.walk(F.analysis("Plan.") + F.answerHeader + "{\"a\":1}<|return|>", constraint) == -1)
    }

    @Test("a header with attributes, a preamble, a call or a second analysis cannot follow the analysis")
    func onlyThePlainAnswerHeaderFollows() throws {
        let constraint = try F.constraint()
        for tail in ["<|start|>assistant<|channel|>final <|constrain|>json<|message|>{}",
                     "<|start|>assistant<|channel|>final json<|message|>{}",
                     "<|start|>assistant<|channel|>commentary<|message|>Checking.",
                     "<|start|>assistant<|channel|>commentary to=functions.lookup <|constrain|>json<|message|>{}",
                     "<|start|>assistant<|channel|>analysis<|message|>more",
                     "{}", "<|return|>"] {
            #expect(F.walk(F.analysis("Plan.") + tail, constraint) == nil, "\(tail)")
        }
        // The analysis header itself is forced: no answer without reasoning first.
        #expect(F.walk(F.answerHeader + "{}", constraint) == nil)
        #expect(F.walk("{}", constraint) == nil)
    }

    @Test("the value follows the schema and ends only once complete")
    func valueFollowsTheSchema() throws {
        let constraint = try F.constraint(F.schemaFormat())
        let prefix = F.analysis("Positive.") + F.answerHeader
        #expect(F.walk(prefix + #"{"sentiment":"positive","score":5}<|return|>"#, constraint) == -1)
        for bad in [#"{"sentiment":"great","score":5}"#, #"{"sentiment":"positive","score":"5"}"#,
                    #"{"sentiment":"positive"}<|return|>"#, #"{"sentiment":"positive","score":5,"x":1}"#,
                    #"```json"#, #"Here: {"#] {
            #expect(F.walk(prefix + bad, constraint) == nil, "\(bad)")
        }
        // `<|return|>` is refused before the value is complete.
        let open = try #require(F.walk(prefix + #"{"sentiment":"positive","#, constraint))
        #expect(!constraint.allowedTokenIDs(state: open, remainingTokens: 100).contains(T.returnToken))
    }

    @Test("reasoning never spells a Harmony control token as text")
    func analysisNeverSpellsMarkers() throws {
        let constraint = try F.constraint()
        for marker in ["<|end|>", "<|return|>", "<|channel|>", "<|start|>", "<|message|>", "<|constrain|>", "<|call|>"] {
            // Byte by byte, the marker's last byte is refused; the control token itself is the only way out.
            let spelled = Array(marker.utf8).map { "\(Character(Unicode.Scalar($0)))" }.joined()
            let text = "<|channel|>analysis<|message|>a " + spelled
            let ids = T.tokens("<|channel|>analysis<|message|>a ") + Array(marker.utf8).map(Int.init)
            var state = 0
            var refused = false
            for (offset, id) in ids.enumerated() {
                guard constraint.allowedTokenIDs(state: state, remainingTokens: 4_000 - offset).contains(id),
                      let next = constraint.nextState(state: state, tokenID: id) else { refused = true; break }
                state = next
            }
            #expect(refused, "\(text)")
        }
    }

    @Test("near the budget the analysis ends so the answer can start")
    func budgetEndsTheAnalysis() throws {
        let constraint = try F.constraint(maxTokens: 400)
        let reasoning = try #require(F.walk("<|channel|>analysis<|message|>think", constraint))
        #expect(constraint.allowedTokenIDs(state: reasoning, remainingTokens: constraint.analysisReserve) == [T.end])
        #expect(constraint.allowedTokenIDs(state: reasoning, remainingTokens: constraint.analysisReserve + 1)
            .count > 200)
        // A budget smaller than the reserve still yields the header and an answer
        // (31 tokens with this byte tokenizer).
        let tight = try F.constraint(maxTokens: 40)
        #expect(tight.maxTokens < tight.analysisReserve)
        let early = try #require(F.walk("<|channel|>analysis<|message|>", tight))
        #expect(tight.allowedTokenIDs(state: early, remainingTokens: 21) == [T.end])
        #expect(F.walk("<|channel|>analysis<|message|><|end|>" + F.answerHeader + "{}<|return|>", tight) == -1)
    }

    @Test("the constraint refuses tokenizers it cannot frame and budgets it cannot serve")
    func refusesWhatItCannotFrame() throws {
        let request = try F.request()
        let answer = try JSONAnswerFormat(#require(request.responseFormat),
            forbidding: JSONAnswerProfile.gptOSSAnswer.contentMarkers, family: "GPT-OSS")
        #expect(throws: ToolConstraintSchemaError.self) {
            try GPTOSSJSONAnswerConstraint(format: answer, tokenizer: T(), vocabulary: F.vocabulary(), maxTokens: 0)
        }
        // A control token missing, or spelled by an ordinary piece below `<|startoftext|>`.
        var missing = T()
        missing.controls = T.controls.filter { $0.0 != "<|channel|>" }
        var ordinary = T()
        ordinary.controls = T.controls.map { $0.0 == "<|message|>" ? ($0.0, 1_000) : $0 }
        for tokenizer in [missing, ordinary] {
            #expect(throws: ToolConstraintSchemaError.self) {
                try GPTOSSJSONAnswerConstraint(format: answer, tokenizer: tokenizer, vocabulary: F.vocabulary(),
                    maxTokens: 64)
            }
        }
    }

    // MARK: - The request policy

    private static let handle = TokenizerHandle(GPTOSSAnswerByteTokenizer())

    private func make(_ request: OpenAIChatCompletionRequest, modelType: String? = "gpt_oss",
                      prompt: [Int] = GPTOSSAnswerByteTokenizer.prompt) throws -> (any CBv2TokenConstraint)? {
        try ToolConstraintFactory.make(prepared: ToolChoicePromptPolicy.prepare(request, modelType: modelType),
            request: request, tokenizer: Self.handle, modelContext: .init(modelId: request.model, modelType: modelType),
            defaultMaxTokens: 100, stopTokenIDs: T.stops, nativePromptTokens: prompt)
    }

    @Test("a GPT-OSS JSON response_format gets the constraint, with the request's budget or the default")
    func eligibleRequestsAreConstrained() throws {
        for format in [["type": "json_object"], F.schemaFormat(), F.schemaFormat(strict: false)] {
            let constraint = try #require(try make(F.request(format: format)) as? GPTOSSJSONAnswerConstraint)
            #expect(constraint.maxTokens == 64 && constraint.fallbackTokenID == T.returnToken)
        }
        let unbounded = try #require(try make(F.request(maxTokens: nil)) as? GPTOSSJSONAnswerConstraint)
        #expect(unbounded.maxTokens == 100)
    }

    @Test("every other request keeps today's prompt-only behavior, without an error")
    func declinedRequestsAreUnconstrained() throws {
        let tool: [String: Any] = ["type": "function", "function": ["name": "lookup", "parameters": ["type": "object"]]]
        let declined: [OpenAIChatCompletionRequest] = try [
            F.request(format: nil), F.request(format: ["type": "text"]),
            F.request(tools: [tool]), F.request(tools: [tool], choice: "auto"), F.request(choice: "none"),
            F.request(stop: ["\n\n"]), F.request(maxTokens: 0),
            F.request(format: F.schemaFormat(["anyOf": [["type": "string"], ["type": "integer"]]])),
            F.request(format: F.schemaFormat(["type": "string", "pattern": "^a"])),
        ]
        for request in declined {
            #expect(try make(request) == nil)
        }
        let request = try F.request()
        for type in ["qwen3_5", "gemma4", "glm5_next", "GPT_OSS", nil] as [String?] {
            #expect(try make(request, modelType: type) == nil, "\(type ?? "nil")")
        }
        #expect(try make(request, prompt: T.tokens("<|start|>user<|message|>hi<|end|>")) == nil)
        let switchedOff = GPTOSSJSONAnswerPolicy.constraint(request: request, tokenizer: Self.handle,
            modelType: "gpt_oss", defaultMaxTokens: 100, stopTokenIDs: T.stops,
            promptTokens: GPTOSSAnswerByteTokenizer.prompt, enabled: false)
        #expect(switchedOff == nil)
    }

    @Test("the switch reads off, 0, false and no as off; anything else as on")
    func switchParsing() {
        for value in ["off", "0", "false", "no", " OFF ", "No"] { #expect(!GPTOSSJSONAnswerPolicy.isEnabled(value)) }
        for value in [nil, "", "on", "1", "true", "yes"] as [String?] { #expect(GPTOSSJSONAnswerPolicy.isEnabled(value)) }
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(GPTOSSJSONAnswerPolicy.environmentKey))
    }
}
