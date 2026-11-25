import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

enum GPTOSSJSONFixture {
    typealias T = HarmonyByteTestTokenizer

    static let schema = #"""
    {"type":"object","properties":{"city":{"type":"string"},"temp":{"type":"integer"},
      "unit":{"type":"string","enum":["c","f"]}},"required":["city"],"additionalProperties":false}
    """#
    /// Pydantic's shape: a nested model behind `$defs`, an `Optional[int]`
    /// with limits, a title on every node.
    static let pydantic = #"""
    {"$defs":{"Place":{"properties":{"name":{"title":"Name","type":"string"}},"required":["name"],
      "title":"Place","type":"object"}},
     "properties":{"place":{"$ref":"#/$defs/Place"},
      "days":{"anyOf":[{"type":"integer","minimum":1,"maximum":7},{"type":"null"}],"default":null,"title":"Days"}},
     "required":["place"],"title":"Forecast","type":"object"}
    """#
    static let jsonObject = #"{"type":"json_object"}"#
    static let final = "<|end|><|start|>assistant<|channel|>final<|message|>"
    /// The header GPT-OSS writes for a JSON answer.
    static let finalJSON = "<|end|><|start|>assistant<|channel|>final <|constrain|>json<|message|>"

    static func schemaFormat(_ schema: String) -> String {
        #"{"type":"json_schema","json_schema":{"name":"out","schema":"# + schema + "}}"
    }

    static func request(format: String?, tools: String? = nil, choice: String? = nil,
                        maxTokens: Int = 400, parser: String = "harmony") throws -> OpenAIChatCompletionRequest {
        // As the provider serves it: the Harmony reasoning parser, decoded as inbound requests are.
        var body = #"{"model":"gpt-oss-20b","messages":[{"role":"user","content":"Weather in Paris?"}],"#
            + #""reasoning_parser":"\#(parser)","max_tokens":\#(maxTokens)"#
        if let format { body += #","response_format":"# + format }
        if let tools { body += #","tools":"# + tools }
        if let choice { body += #","tool_choice":"# + choice }
        return try ProviderLoop.decodeOpenAIRequest(Data((body + "}").utf8), modelType: "gpt_oss")
    }

    static func vocabulary() throws -> JSONAnswerVocabulary {
        var pieces = [[UInt8]](repeating: [], count: JSONAnswerProfile.gptOSSFinal.vocabularySize)
        for byte in 0...255 { pieces[byte] = [UInt8(byte)] }
        return try JSONAnswerVocabulary(pieces: pieces, profile: .gptOSSFinal, stopTokenIDs: T.stops)
    }

    /// The format compiled as admission compiles it (widened when needed).
    static func constraint(format: String = schemaFormat(schema), maxTokens: Int = 4_096) throws
        -> GPTOSSJSONAnswerConstraint {
        let responseFormat = try #require(try request(format: format).responseFormat)
        let answer = try #require(QwenJSONSchemaRewrite.answerFormat(responseFormat, profile: .gptOSSFinal,
                                                                    widens: true))
        return try GPTOSSJSONAnswerConstraint(format: answer.format, tokenizer: T(), vocabulary: vocabulary(),
                                              maxTokens: maxTokens)
    }

    static func analysis(_ text: String) -> String { "<|channel|>analysis<|message|>" + text }
}

@Suite("GPT-OSS JSON answers")
struct GPTOSSJSONAnswerTests {
    private typealias J = GPTOSSJSONFixture
    private typealias A = GPTOSSAutoFixture
    private typealias T = HarmonyByteTestTokenizer

    // MARK: - The automaton

    @Test("the analysis, then the final header, then one JSON value of the schema and <|return|>")
    func answerFollowsTheSchema() throws {
        let constraint = try J.constraint()
        #expect(constraint.mode == .auto && constraint.fallbackTokenID == T.returnToken)
        for answer in [#"{"city":"Paris","temp":21,"unit":"c"}"#, #"{"unit":"f","city":"Oslo"}"#, #"{"city":""}"#] {
            let output = J.analysis("The user wants Paris.") + J.final + answer
            let state = try #require(A.walk(output, constraint), "\(answer)")
            #expect(constraint.allowedTokenIDs(state: state, remainingTokens: 100).contains(T.returnToken), "\(answer)")
            #expect(constraint.nextState(state: state, tokenID: T.returnToken) == -1)
        }
        // An empty analysis is an analysis.
        let quick = try #require(A.walk(J.analysis("") + J.final + #"{"city":"Rome"}"#, constraint))
        #expect(constraint.nextState(state: quick, tokenID: T.returnToken) == -1)
        // The header GPT-OSS writes for JSON answers leads to the same answer.
        let constrained = try #require(A.walk(J.analysis("x") + J.finalJSON + #"{"city":"Oslo"}"#, constraint))
        #expect(constraint.nextState(state: constrained, tokenID: T.returnToken) == -1)
        #expect(A.walk(J.analysis("x") + J.finalJSON + "1", constraint) == nil)
        // After `final` both headers stay open: `<|message|>` or a space.
        let channel = try #require(A.walk(J.analysis("x") + "<|end|><|start|>assistant<|channel|>final", constraint))
        #expect(constraint.allowedTokenIDs(state: channel, remainingTokens: 100) == [Int(UInt8(ascii: " ")), T.message])
    }

    @Test("only the Harmony framing is admitted around the answer")
    func framingIsFixed() throws {
        let constraint = try J.constraint()
        #expect(constraint.allowedTokenIDs(state: 0, remainingTokens: 100) == [T.channel])
        for output in [
            "<|channel|>final<|message|>{",
            "<|channel|>commentary<|message|>hi",
            J.analysis("x") + "<|end|><|start|>assistant<|channel|>analysis<|message|>",
            J.analysis("x") + "<|end|><|start|>assistant<|channel|>commentary<|message|>",
            J.analysis("x") + "<|end|><|start|>assistant to=functions.x<|channel|>",
            J.analysis("x") + "<|end|><|start|>assistant<|channel|>final <|constrain|>xml",
            J.analysis("x") + "<|end|><|start|>assistant<|channel|>final json<|message|>",
            J.analysis("x") + "<|return|>",
            J.analysis("x") + "<|call|>",
            J.analysis("x") + "<|start|>",
            J.analysis("spells <|return|>"),
        ] {
            #expect(A.walk(output, constraint) == nil, "\(output)")
        }
        let reasoning = try #require(A.walk(J.analysis("Paris, 21 degrees."), constraint))
        let allowed = constraint.allowedTokenIDs(state: reasoning, remainingTokens: 1_000)
        #expect(allowed.contains(T.end) && !allowed.contains(T.returnToken) && !allowed.contains(T.call))
        #expect(!allowed.contains(T.start) && !allowed.contains(T.endOfText))
        let ended = try #require(A.walk("<|end|>", constraint, from: reasoning))
        #expect(constraint.allowedTokenIDs(state: ended, remainingTokens: 100) == [T.start])
    }

    @Test("an answer outside the schema cannot be generated, and <|return|> waits for a complete value")
    func answerOutsideTheSchemaIsImpossible() throws {
        let constraint = try J.constraint()
        let answer = try #require(A.walk(J.analysis("ok") + J.final, constraint))
        #expect(!constraint.allowedTokenIDs(state: answer, remainingTokens: 100).contains(T.returnToken))
        for invalid in ["Sure", #"{"city":1"#, #"{"town""#, #"{"city":"Paris","city""#, #"{"unit":"k""#,
                        #"{"city":"<|end|>"#, #"{"city":"Paris"}}"#, "[", #""Paris""#] {
            #expect(A.walk(invalid, constraint, from: answer) == nil, "\(invalid)")
        }
        let open = try #require(A.walk(#"{"city":"Paris""#, constraint, from: answer))
        #expect(!constraint.allowedTokenIDs(state: open, remainingTokens: 100).contains(T.returnToken))
        #expect(constraint.nextState(state: open, tokenID: T.returnToken) == nil)
        // The required key is required.
        let missing = try #require(A.walk(#"{"temp":3"#, constraint, from: answer))
        #expect(A.walk("}", constraint, from: missing) == nil)
    }

    @Test("json_object holds the answer to one JSON object")
    func jsonObjectIsAnObject() throws {
        let constraint = try J.constraint(format: J.jsonObject)
        let answer = try #require(A.walk(J.analysis("x") + J.final, constraint))
        for invalid in ["[1]", #""text""#, "42", "Here", "{\"a\":1}}"] {
            #expect(A.walk(invalid, constraint, from: answer) == nil, "\(invalid)")
        }
        let object = try #require(A.walk(#"{"a":[1,{"b":null}],"c":"d"}"#, constraint, from: answer))
        #expect(constraint.nextState(state: object, tokenID: T.returnToken) == -1)
    }

    @Test("a Pydantic schema is held to its structure; a limit it cannot spell is the model's")
    func pydanticSchemaIsWidened() throws {
        let constraint = try J.constraint(format: J.schemaFormat(J.pydantic))
        let answer = try #require(A.walk(J.analysis("x") + J.final, constraint))
        for valid in [#"{"place":{"name":"Paris"},"days":3}"#, #"{"place":{"name":"Paris"},"days":null}"#,
                      #"{"place":{"name":"Paris"},"days":40}"#, #"{"place":{"name":"Paris"}}"#] {
            let state = try #require(A.walk(valid, constraint, from: answer), "\(valid)")
            #expect(constraint.nextState(state: state, tokenID: T.returnToken) == -1, "\(valid)")
        }
        for invalid in [#"{"place":"Paris""#, #"{"place":{"name":"Paris"},"days":"3""#, #"{"days":1}"#] {
            #expect(A.walk(invalid, constraint, from: answer) == nil, "\(invalid)")
        }
    }

    @Test("the analysis ends within the answer's reserve, and the reserve leaves room for the answer")
    func analysisEndsWithinTheReserve() throws {
        let constraint = try J.constraint()
        let header = T.tokens("<|channel|>analysis<|message|>").count
        let reasoning = try #require(A.walk(J.analysis("x"), constraint))
        let used = header + 1
        #expect(constraint.allowedTokenIDs(state: reasoning, remainingTokens: constraint.analysisReserve) == [T.end])
        #expect(constraint.maskCacheKey(state: reasoning, remainingTokens: constraint.analysisReserve) == -1)
        #expect(constraint.allowedTokenIDs(state: reasoning, remainingTokens: constraint.analysisReserve + 1).count > 1)
        // Once `analysisCap` tokens are out, whatever the budget.
        let long = try J.constraint(maxTokens: GPTOSSJSONAnswerConstraint.analysisCap * 2)
        let longReasoning = try #require(A.walk(J.analysis("x"), long))
        #expect(long.allowedTokenIDs(state: longReasoning,
            remainingTokens: long.maxTokens - GPTOSSJSONAnswerConstraint.analysisCap) == [T.end])
        #expect(long.allowedTokenIDs(state: longReasoning, remainingTokens: long.maxTokens - used).count > 1)
        let longestHeader = GPTOSSJSONAnswerConstraint.finalHeaderTexts.map { T.tokens($0).count }.max() ?? 0
        #expect(constraint.analysisReserve == 1 + longestHeader
            + GPTOSSJSONAnswerConstraint.answerAllowance(maxTokens: constraint.maxTokens) + 1)
    }

    @Test("the answer allowance is half the budget, between 64 and 256 tokens")
    func answerAllowanceScalesWithTheBudget() throws {
        typealias C = GPTOSSJSONAnswerConstraint
        #expect(C.answerAllowance(maxTokens: 100) == 64 && C.answerAllowance(maxTokens: 300) == 150)
        #expect(C.answerAllowance(maxTokens: 512) == 256 && C.answerAllowance(maxTokens: 131_072) == 256)
        // At `max_tokens` 300 the reasoning keeps over a third of the budget.
        let constraint = try J.constraint(maxTokens: 300)
        let longestHeader = C.finalHeaderTexts.map { T.tokens($0).count }.max() ?? 0
        #expect(constraint.analysisReserve == 1 + longestHeader + 150 + 1)
        let reasoning = try #require(A.walk(J.analysis("x"), constraint))
        #expect(constraint.allowedTokenIDs(state: reasoning, remainingTokens: constraint.analysisReserve) == [T.end])
        #expect(constraint.allowedTokenIDs(state: reasoning, remainingTokens: constraint.analysisReserve + 1).count > 1)
        #expect(300 - constraint.analysisReserve >= 120)
    }

    @Test("masks do not change between calls, and asking for one interns nothing")
    func masksArePure() throws {
        let constraint = try J.constraint()
        let state = try #require(A.walk(J.analysis("x") + J.final + #"{"ci"#, constraint))
        let before = constraint.cachedStateCount
        let first = constraint.allowedTokenIDs(state: state, remainingTokens: 10)
        _ = constraint.allowedTokenIDs(state: 0, remainingTokens: 10)
        #expect(constraint.allowedTokenIDs(state: state, remainingTokens: 9) == first)
        #expect(constraint.cachedStateCount == before && first == [Int(UInt8(ascii: "t"))])
        #expect(constraint.allowedTokenIDs(state: state, remainingTokens: 0) == [])
        #expect(constraint.allowsChainedDecode)
    }

    @Test("a final header the tokenizer cannot encode exactly refuses the constraint")
    func finalHeaderMustEncodeExactly() throws {
        // The Harmony controls verify, but `final` encodes to an added id.
        var tokenizer = T()
        tokenizer.controls.append(("final", 200013))
        let responseFormat = try #require(try J.request(format: J.jsonObject).responseFormat)
        let answer = try #require(QwenJSONSchemaRewrite.answerFormat(responseFormat, profile: .gptOSSFinal, widens: true))
        #expect(throws: ToolConstraintSchemaError.self) {
            try GPTOSSJSONAnswerConstraint(format: answer.format, tokenizer: tokenizer, vocabulary: J.vocabulary(),
                                           maxTokens: 100)
        }
        #expect(throws: ToolConstraintSchemaError.self) {
            try GPTOSSJSONAnswerConstraint(format: answer.format, tokenizer: T(), vocabulary: J.vocabulary(),
                                           maxTokens: 0)
        }
    }

    // MARK: - Admission

    @Test("only tool-free GPT-OSS JSON requests on an engine that runs constraints get the grammar")
    func admission() throws {
        let handle = TokenizerHandle(T())
        func make(_ request: OpenAIChatCompletionRequest, modelType: String = "gpt_oss", prompt: [Int]? = T.prompt,
                  runs: Bool = true, enabled: Bool = true, tokenizer: TokenizerHandle = handle)
            -> GPTOSSJSONAnswerConstraint? {
            GPTOSSJSONAnswers.constraint(request: request, modelType: modelType, tokenizer: tokenizer,
                maxTokens: 200, stopTokenIDs: T.stops, promptTokens: prompt, runsTokenConstraints: runs,
                enabled: enabled)
        }
        for format in [J.jsonObject, J.schemaFormat(J.schema), J.schemaFormat(J.pydantic)] {
            let built = try #require(make(try J.request(format: format)), "\(format)")
            #expect(built.maxTokens == 200 && built.format.family == "GPT-OSS final")
        }
        let eligible = try J.request(format: J.jsonObject)
        #expect(make(eligible, enabled: false) == nil)
        for type in ["qwen3_5", "gemma4", "GPT_OSS_X"] { #expect(make(eligible, modelType: type) == nil, "\(type)") }
        #expect(make(eligible, runs: false) == nil)
        #expect(make(eligible, prompt: T.tokens("<|start|>user<|message|>hi<|end|>")) == nil)
        #expect(make(eligible, prompt: nil) == nil)
        #expect(make(try J.request(format: #"{"type":"text"}"#)) == nil)
        #expect(make(try J.request(format: nil)) == nil)
        let tools = #"[{"type":"function","function":{"name":"weather","parameters":{"type":"object"}}}]"#
        #expect(make(try J.request(format: J.jsonObject, tools: tools)) == nil)
        #expect(make(try J.request(format: J.jsonObject, choice: #""none""#)) == nil)
        // Another reasoning parser would not read the final headers as the answer.
        #expect(make(try J.request(format: J.jsonObject, parser: "none")) == nil)
        // A format the subset cannot hold even widened, at a non-object root.
        #expect(make(try J.request(format: J.schemaFormat(#"{"anyOf":[{"type":"string"},{"type":"integer"}]}"#)))
            == nil)
        // A tokenizer that fails the Harmony checks: prompt-only, no error.
        var missing = T()
        missing.controls.removeAll { $0.0 == "<|constrain|>" }
        #expect(make(eligible, tokenizer: TokenizerHandle(missing)) == nil)
    }

    @Test("the call arguments' and the final answer's vocabularies stay apart")
    func vocabulariesStayApart() throws {
        let handle = TokenizerHandle(T())
        let call = try JSONAnswerVocabulary.cached(for: handle, profile: .gptOSS, stopTokenIDs: T.stops)
        let final = try JSONAnswerVocabulary.cached(for: handle, profile: .gptOSSFinal, stopTokenIDs: T.stops)
        #expect(call.answerEOS == [T.call] && final.answerEOS == [T.returnToken])
        #expect(QwenJSONSchemaRewrite.widenedFamilies.contains(JSONAnswerProfile.gptOSSFinal.family))
        #expect(!QwenJSONSchemaRewrite.widenedFamilies.contains(JSONAnswerProfile.gptOSS.family))
    }

    @Test("the switch, its passthrough and its name outside the prefix-cache identity")
    func killSwitch() {
        for value in [nil, "", "on", "1", "true"] { #expect(GPTOSSJSONAnswers.isEnabled(value)) }
        for value in ["off", "OFF", "0", "false", "no", " off ", "none", "disabled"] {
            #expect(!GPTOSSJSONAnswers.isEnabled(value), "\(value)")
        }
        let key = GPTOSSJSONAnswers.environmentKey
        #expect(key == "DARKBLOOM_HARMONY_JSON_ANSWERS" && !key.hasPrefix("DARKBLOOM_GPTOSS_"))
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "off"])[key] == "off")
    }

    @Test("the loop guard stays off for JSON answers")
    func loopGuardStaysOff() throws {
        let request = try J.request(format: J.jsonObject)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gpt_oss")
        #expect(GenerationLoopGuardPolicy.resolve(modelType: "gpt_oss", request: request, prepared: prepared,
            tokenConstraint: try J.constraint(format: J.jsonObject), setting: .modelTypes(["gpt_oss"])) == nil)
    }
}
