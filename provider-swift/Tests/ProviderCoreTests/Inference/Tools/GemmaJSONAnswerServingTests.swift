import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

@Suite("Gemma JSON answer request policy")
struct GemmaJSONAnswerPolicyTests {
    private typealias F = GemmaAnswerFixture
    /// One verified handle, so its vocabulary is built once for the suite.
    private static let handle = TokenizerHandle(GemmaPieceTestTokenizer(), toolConstraintContractVerified: true)

    static func request(format: String?, tools: String? = nil, choice: String? = nil, parser: String? = "gemma4",
                        stop: String? = nil, maxTokens: Int = 64, image: Bool = false) throws
        -> OpenAIChatCompletionRequest {
        let content = image
            ? #"[{"type":"text","text":"hi"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]"#
            : #""hi""#
        var body = #"{"model":"gemma-4-26b-qat-4bit","messages":[{"role":"user","content":"# + content
            + #"}],"max_tokens":\#(maxTokens)"#
        if let format { body += #","response_format":"# + format }
        if let tools { body += #","tools":"# + tools }
        if let choice { body += #","tool_choice":"# + choice }
        if let parser { body += #","reasoning_parser":""# + parser + #"""# }
        if let stop { body += #","stop":"# + stop }
        return try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data((body + "}").utf8))
    }

    private func make(_ request: OpenAIChatCompletionRequest, modelType: String? = "gemma4",
                      thinking: Bool = false, prompt: String? = nil, handle: TokenizerHandle = Self.handle,
                      stops: Set<Int> = F.stops) throws -> (any CBv2TokenConstraint)? {
        let tokens = F.tokenizer.encode(text: prompt ?? GemmaPieceTestTokenizer.prompt(thinking: thinking),
                                        addSpecialTokens: false)
        return try ToolConstraintFactory.make(prepared: ToolChoicePromptPolicy.prepare(request, modelType: modelType),
            request: request, tokenizer: handle, modelContext: .init(modelId: request.model, modelType: modelType),
            defaultMaxTokens: 100, stopTokenIDs: stops, nativePromptTokens: tokens)
    }

    @Test func eligibleRequestsStartWhereThePromptLeavesTheModel() throws {
        for format in [F.jsonObject, F.schemaFormat(F.schema)] {
            for (thinking, phase) in [(false, GemmaJSONAnswerBoundary.Phase.answer), (true, .opening)] {
                for modelType in ["gemma4", "gemma4_text"] {
                    let constraint = try #require(try make(Self.request(format: format), modelType: modelType,
                        thinking: thinking) as? GemmaJSONAnswerConstraint)
                    #expect(constraint.initialPhase == phase && constraint.format.family == "Gemma")
                    #expect(constraint.maxTokens == 64 && constraint.fallbackTokenID == 106)
                }
            }
        }
        // A tool-free `auto` is the same request.
        #expect(try make(Self.request(format: F.jsonObject, choice: #""auto""#)) is GemmaJSONAnswerConstraint)
        var unbounded = try Self.request(format: F.jsonObject)
        unbounded.maxTokens = nil
        #expect((try make(unbounded) as? GemmaJSONAnswerConstraint)?.maxTokens == 100)
    }

    @Test func theSwitchRestoresPromptOnlyAnswers() throws {
        for (value, on) in [(nil, true), ("", true), ("1", true), ("on", true), ("off", false), (" OFF ", false),
                            ("0", false), ("false", false), ("no", false)] as [(String?, Bool)] {
            #expect(GemmaJSONAnswerPolicy.isEnabled(value) == on, "\(value ?? "unset")")
        }
        let request = try Self.request(format: F.jsonObject)
        let tokens = F.tokenizer.encode(text: GemmaPieceTestTokenizer.prompt(thinking: false), addSpecialTokens: false)
        #expect(GemmaJSONAnswerPolicy.constraint(request: request, tokenizer: Self.handle, modelType: "gemma4",
            defaultMaxTokens: 100, stopTokenIDs: F.stops, promptTokens: tokens, enabled: false) == nil)
        #expect(GemmaJSONAnswerPolicy.constraint(request: request, tokenizer: Self.handle, modelType: "gemma4",
            defaultMaxTokens: 100, stopTokenIDs: F.stops, promptTokens: tokens, enabled: true) != nil)
    }

    @Test func requestsOutOfScopeKeepTodaysBehaviorWithoutAnError() throws {
        let tools = #"[{"type":"function","function":{"name":"weather","parameters":{"type":"object","properties":{"city":{"type":"string"}}}}}]"#
        let format = F.jsonObject
        let out: [OpenAIChatCompletionRequest] = try [
            Self.request(format: format, tools: tools), Self.request(format: format, tools: tools, choice: #""auto""#),
            Self.request(format: format, choice: #""none""#), Self.request(format: format, stop: #"["END"]"#),
            Self.request(format: format, image: true), Self.request(format: format, parser: "qwen3"),
            Self.request(format: format, parser: nil), Self.request(format: format, maxTokens: 0),
            Self.request(format: #"{"type":"text"}"#), Self.request(format: nil),
        ]
        // Tools and `tool_choice` keep their own Gemma paths; the rest stay unconstrained.
        for request in out { #expect(!(try make(request) is GemmaJSONAnswerConstraint)) }
        let request = try Self.request(format: format)
        for type in ["qwen3_5", "gpt_oss", "diffusion_gemma", "gemma3", "Gemma4", nil] as [String?] {
            #expect(try make(request, modelType: type) == nil, "\(type ?? "nil")")
        }
        // An unpinned template, another prompt end, another tokenizer, or
        // stops without `<turn|>` decline too.
        #expect(try make(request, handle: TokenizerHandle(GemmaPieceTestTokenizer())) == nil)
        #expect(try make(request, prompt: "<bos><|turn>user\nhi<turn|>\n<|turn>model\n{\"pre") == nil)
        var moved = GemmaPieceTestTokenizer()
        moved.specials[101] = nil
        moved.specials[102] = "<channel|>"
        #expect(try make(request, handle: TokenizerHandle(moved, toolConstraintContractVerified: true)) == nil)
        #expect(try make(request, stops: [1, 50]) == nil)
    }

    @Test func clientSchemaShapesAreRewrittenIntoTheSubsetExactly() throws {
        // Pydantic / OpenAI strict conversion, zod-to-json-schema (named: a root $ref) and one-branch allOf shapes.
        let nullableEnum =
            ##"{"type":"object","properties":{"e":{"anyOf":[{"$ref":"#/$defs/E"},{"type":"null"}]}},"$defs":{"E":{"type":"string","enum":["x","y"]}}}"##
        let rewritten = [
            ##"{"type":"object","properties":{"a":{"$ref":"#/$defs/A"}},"$defs":{"A":{"type":"string"}},"required":["a"]}"##,
            #"{"type":"object","properties":{"a":{"anyOf":[{"type":"string"},{"type":"null"}],"default":null}}}"#,
            ##"{"$schema":"http://json-schema.org/draft-07/schema#","type":"object","properties":{}}"##,
            ##"{"$schema":"http://json-schema.org/draft-07/schema#","definitions":{"B":{"type":"integer"}},"type":"object","properties":{"b":{"$ref":"#/definitions/B","description":"n"}}}"##,
            ##"{"type":"object","properties":{"c":{"allOf":[{"$ref":"#/$defs/C"}],"title":"C"}},"$defs":{"C":{"type":"boolean"}}}"##,
            nullableEnum,
            ##"{"$ref":"#/definitions/P","definitions":{"P":{"type":"object","properties":{"p":{"type":"string"}},"required":["p"]}},"$schema":"http://json-schema.org/draft-07/schema#"}"##,
        ]
        for schema in rewritten {
            let constraint = try #require(try make(Self.request(format: F.schemaFormat(schema)))
                as? GemmaJSONAnswerConstraint, "\(schema)")
            #expect(constraint.format.schema != nil, "enforced as written: \(schema)")
        }
        // The nullable enum admits its values and null, nothing else.
        let e = try F.constraint(F.schemaFormat(nullableEnum))
        for value in [#""x""#, #""y""#, "null"] {
            #expect(F.walk(F.ids(#"{"e": "# + value + "}"), e) != nil, "\(value)")
        }
        #expect(F.walk(F.ids(#"{"e": "z"#), e) == nil)
    }

    private static func json(_ text: String) throws -> MLXLMCommon.JSONValue {
        try JSONDecoder().decode(MLXLMCommon.JSONValue.self, from: Data(text.utf8))
    }

    private static func rewrite(_ text: String) throws -> MLXLMCommon.JSONValue? {
        ResponseSchemaRewrite.subset(try json(text))
    }

    @Test func theRewriteWritesTheSubsetsSpellings() throws {
        let cases = [
            // anyOf [S, null] over an object, an array (through a reference), const, a type array, an enum with null.
            (#"{"anyOf":[{"type":"object","properties":{"x":{"type":"string"}}},{"type":"null"}]}"#,
             #"{"type":"object","properties":{"x":{"type":"string"}},"nullable":true}"#),
            (##"{"anyOf":[{"type":"array","items":{"$ref":"#/$defs/I"}},{"type":"null"}],"$defs":{"I":{"type":"integer"}}}"##,
             #"{"type":"array","items":{"type":"integer"},"nullable":true}"#),
            (#"{"anyOf":[{"type":"null"},{"const":"a","title":"A"}]}"#, #"{"enum":["a",null],"title":"A","nullable":true}"#),
            (#"{"anyOf":[{"type":["string","null"],"enum":["x"]},{"type":"null"}]}"#,
             #"{"type":["string","null"],"enum":["x",null],"nullable":true}"#),
            (#"{"anyOf":[{"type":"string","enum":["x",null]},{"type":"null"}]}"#,
             #"{"type":"string","enum":["x",null],"nullable":true}"#),
            // Annotations beside a reference or a one-branch allOf go, $comment everywhere, the root's $id and $schema.
            (##"{"$ref":"#/definitions/P","description":"d","definitions":{"P":{"type":"boolean","$comment":"c"}}}"##,
             #"{"type":"boolean"}"#),
            (#"{"allOf":[{"type":"integer"}],"title":"t"}"#, #"{"type":"integer"}"#),
            (##"{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://example.com/s","type":"string"}"##,
             #"{"type":"string"}"#),
            (##"{"$schema":"http://json-schema.org/draft-07/schema#","type":"string"}"##, #"{"type":"string"}"#),
        ]
        for (input, expected) in cases {
            #expect(try Self.rewrite(input) == Self.json(expected), "\(input)")
        }
    }

    @Test func theRewriteRefusesWhatItCannotSayExactlyWithinItsBounds() throws {
        let refused = [
            // Draft-04 has no const, and draft-03 spells required as a boolean.
            ##"{"$schema":"http://json-schema.org/draft-04/schema#","type":"string","const":"a"}"##,
            #"{"$schema":4,"type":"string"}"#, #"{"$schema":"json-schema.org/draft-07/schema","type":"string"}"#,
            #"{"allOf":[{"type":"string"},{"type":"string"}]}"#,
            #"{"anyOf":[{"type":"string"},{"type":"null"}],"minLength":1}"#,
            #"{"anyOf":[{"type":"string"},{"type":["null"]}]}"#,
            #"{"anyOf":[{"type":"null"},{"type":"null"}]}"#,
            #"{"type":"object","$defs":[]}"#,
            // A pointer reads `a/b` as a path and `a~1b` as the name `a/b`: none of these is guessed.
            ##"{"$ref":"#/$defs/a/b","$defs":{"a/b":{"type":"string"},"a":{"type":"object","b":{"type":"integer"}}}}"##,
            ##"{"$ref":"#/$defs/a~1b","$defs":{"a/b":{"type":"string"}}}"##,
            ##"{"$ref":"#/$defs/a%2Fb","$defs":{"a/b":{"type":"string"}}}"##,
            ##"{"$ref":"#/$defs/A","$defs":{"A":{"$ref":"#/$defs/A"}}}"##,
            // The compiler refuses a key longer than additionalProperties; a definition name is at most 256 bytes.
            #"{"type":"string","\#(String(repeating: "k", count: 21))":0}"#,
            // Read on every copy: type names of at most 7 bytes, 128 required names of at most 64.
            #"{"type":"integers"}"#, #"{"type":["string","nullable"]}"#,
            #"{"type":["string"\#(String(repeating: #","null""#, count: 20_000))]}"#,
            #"{"type":"object","properties":{"a":{"type":"string"}},"required":["\#(String(repeating: "a", count: 65))"]}"#,
            #"{"type":"object","properties":{"a":{"type":"string"}},"required":[\#(Array(repeating: #""a""#, count: 129).joined(separator: ","))]}"#,
            ##"{"$ref":"#/$defs/\##(String(repeating: "d", count: 257))","$defs":{"\##(String(repeating: "d", count: 257))":{"type":"string"}}}"##,
        ]
        for schema in refused { #expect(try Self.rewrite(schema) == nil, "\(schema)") }
        let widest = String(repeating: "a", count: 64)
        for accepted in [#"{"type":"INTEGER"}"#, #"{"type":["boolean","null","null"]}"#,
                         #"{"type":"object","properties":{"a":{"type":"string"}},"required":["a"]}"#,
                         #"{"type":"object","properties":{"\#(widest)":{"type":"string"}},"required":["\#(widest)"]}"#] {
            #expect(try Self.rewrite(accepted) == Self.json(accepted), "\(accepted)")
        }
        let longest = String(repeating: "d", count: 256)
        #expect(try Self.rewrite(##"{"$ref":"#/$defs/\##(longest)","$defs":{"\##(longest)":{"type":"string"}}}"##)
                == Self.json(#"{"type":"string"}"#))
        // Every definition refers to the next: directly, through a property, or through two properties.
        func chain(_ count: Int, _ body: (Int) -> String) -> String {
            ##"{"$ref":"#/$defs/D0","$defs":{"## + (0..<count).map { ##""D\##($0)":"## + body($0) }.joined(separator: ",")
                + ##","D\##(count)":{"type":"string"}}}"##
        }
        let reference = { (level: Int) in ##"{"$ref":"#/$defs/D\##(level + 1)"}"## }
        let property = { (level: Int) in
            ##"{"type":"object","properties":{"n":{"$ref":"#/$defs/D\##(level + 1)"}}}"##
        }
        let twice = { (level: Int) in
            ##"{"type":"object","properties":{"l":{"$ref":"#/$defs/D\##(level + 1)"},"r":{"$ref":"#/$defs/D\##(level + 1)"}}}"##
        }
        #expect(try Self.rewrite(chain(4, reference)) == Self.json(#"{"type":"string"}"#))
        #expect(try Self.rewrite(chain(4_000, reference)) == nil, "at most \(ResponseSchemaRewrite.maximumUnwraps) in a row")
        // The deepest output the rewrite writes is one the compiler takes.
        let deepest = try #require(try Self.rewrite(chain(ToolConstraintSchemaCompiler.maxDepth, property)))
        #expect((try? ToolConstraintSchemaCompiler.compileResponseSchema(deepest)) != nil)
        #expect(try Self.rewrite(chain(ToolConstraintSchemaCompiler.maxDepth + 1, property)) == nil,
                "at most \(ToolConstraintSchemaCompiler.maxDepth) levels")
        #expect(try Self.rewrite(chain(4, twice)) != nil)
        #expect(try Self.rewrite(chain(12, twice)) == nil, "at most \(ResponseSchemaRewrite.maximumWork)")
        // Copying is paid for too: a definition of 5,000 keys reached from 64 properties.
        let wide = "{" + (0..<5_000).map { #""k\#($0)":0"# }.joined(separator: ",") + #","properties":{}}"#
        let fanOut = #"{"type":"object","properties":{"#
            + (0..<64).map { ##""p\##($0)":{"$ref":"#/$defs/B"}"## }.joined(separator: ",")
            + ##"},"$defs":{"B":"## + wide + "}}"
        #expect(try Self.rewrite(fanOut) == nil, "at most \(ResponseSchemaRewrite.maximumWork)")
        // So are the bytes it hashes: a 100,000-byte reference from 64 properties, 64 names of 32,768 bytes.
        let long = String(repeating: "x", count: 100_000)
        let longReference = #"{"type":"object","properties":{"#
            + (0..<64).map { ##""p\##($0)":{"$ref":"#/$defs/\##(long)"}"## }.joined(separator: ",")
            + ##"},"$defs":{""## + long + #"":{"type":"string"}}}"#
        let longNames = #"{"type":"object","properties":{"#
            + (0..<64).map { #""\#(long.prefix(32_768))\#($0)":{"type":"string"}"# }.joined(separator: ",") + "}}"
        #expect(try Self.rewrite(longReference) == nil)
        #expect(try Self.rewrite(longNames) == nil)
    }

    @Test func aPydanticSchemaKeepsItsKeysAndRequirements() throws {
        // The GPU check's one miss before the rewrite: a stray token became a key of the JSON-object fallback.
        let person = ##"""
        {"$defs":{"Address":{"properties":{"street":{"title":"Street","type":"string"},"city":{"title":"City","type":"string"}},
          "required":["street","city"],"title":"Address","type":"object","additionalProperties":false}},
         "properties":{"name":{"title":"Name","type":"string"},"address":{"$ref":"#/$defs/Address"},
          "nickname":{"anyOf":[{"type":"string"},{"type":"null"}],"title":"Nickname"}},
         "required":["name","address","nickname"],"title":"Person","type":"object","additionalProperties":false}
        """##
        let constraint = try F.constraint(F.schemaFormat(person))
        #expect(constraint.format.schema != nil)
        for nickname in ["null", #""Sofi""#] {
            let c = try F.constraint(F.schemaFormat(person))
            let end = try #require(F.walk(F.ids(#"{"address": {"city": "Bogotá", "street": "Carrera 7"}, "name": "Sofía", "nickname": "#
                + nickname + "}"), c), "\(nickname)")
            #expect(c.nextState(state: end, tokenID: F.turnEnd) == -1)
        }
        let key = try #require(F.walk(F.ids(#"{"address": {""#), constraint))
        #expect(!F.allows(constraint, key, F.space), "no undeclared key, not even a stray space")
        let missing = try #require(F.walk(F.ids(#"{"address": {"city": "B""#), constraint))
        #expect(!F.allows(constraint, missing, F.id("}")), "street is required")
    }

    @Test func schemasOutsideTheSubsetFallBackToAnObjectOrToPromptOnly() throws {
        let objectRoots = [
            #"{"type":"object","properties":{"a":{"type":"string","pattern":"^x"}}}"#,
            #"{"type":"object","properties":{"a":{"type":"string","format":"email"}}}"#,
            ##"{"type":"object","properties":{"n":{"$ref":"#/$defs/N"}},"$defs":{"N":{"type":"object","properties":{"next":{"$ref":"#/$defs/N"}}}}}"##,
            ##"{"type":"object","properties":{"a":{"$ref":"#/$defs/A","minLength":2}},"$defs":{"A":{"type":"string"}}}"##,
            #"{"type":"object","properties":{"a":{"anyOf":[{"type":"string"},{"type":"integer"}]}}}"#,
            #"{"type":"object","properties":{"a":{"type":"string","enum":["ok","<eos>"]}}}"#,
            ##"{"type":"object","properties":{"a":{"$ref":"https://example.com/a.json"}}}"##,
            // The rewrite leaves these to the compiler, which refuses them.
            ##"{"type":"object","properties":{"a":{"$id":"https://example.com/a","type":"string"}}}"##,
            ##"{"type":"object","properties":{"a":{"$anchor":"a","type":"string"}}}"##,
            ##"{"type":"object","properties":{"a":{"$defs":{"B":{"type":"string"}},"type":"string"}}}"##,
            ##"{"$schema":"http://json-schema.org/draft-04/schema#","type":"object","properties":{"a":{"const":"x"}}}"##,
        ]
        for schema in objectRoots {
            let constraint = try #require(try make(Self.request(format: F.schemaFormat(schema)))
                as? GemmaJSONAnswerConstraint, "\(schema)")
            #expect(constraint.format.schema == nil, "held to a JSON object: \(schema)")
            #expect(F.walk(F.ids(#"{"anything": [1]}"#), constraint) != nil)
            #expect(!F.allows(constraint, 0, F.id("[")))
        }
        let otherRoots = [
            ##"{"$ref":"#/$defs/A","type":"object","$defs":{"A":{"type":"string"}}}"##,
            #"{"anyOf":[{"type":"string"},{"type":"integer"}]}"#, #"{"type":"string","pattern":"^a"}"#,
            #"{"type":["object","array"],"items":{"type":"string"}}"#, "{}", #"{"type":"string","enum":["<eos>"]}"#,
        ]
        for schema in otherRoots { #expect(try make(Self.request(format: F.schemaFormat(schema))) == nil, "\(schema)") }
        #expect(try make(Self.request(format: #"{"type":"json_schema"}"#)) == nil)
        // A supported schema is enforced as written.
        let exact = try #require(try make(Self.request(format: F.schemaFormat(F.schema))) as? GemmaJSONAnswerConstraint)
        #expect(exact.format.schema != nil)
    }

    private final class OtherConstraint: CBv2TokenConstraint, @unchecked Sendable {
        let mode = CBv2TokenConstraintMode.required
        let maxTokens = 1, initialState = 0, fallbackTokenID = 1
        func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] { [1] }
        func nextState(state: Int, tokenID: Int) -> Int? { -1 }
    }

    @Test func anEngineWithoutConstraintsServesTheAnswerPromptOnly() throws {
        let gemma = try F.constraint()
        let other = OtherConstraint()
        for (pair, native) in [(true, false), (false, true), (true, true)] {
            #expect(EngineV2Bridge.admittedConstraint(gemma, servesDistributedPair: pair,
                tracksNativeShutdown: native) == nil)
            // Every other constraint keeps today's typed refusal there.
            #expect(EngineV2Bridge.admittedConstraint(other, servesDistributedPair: pair,
                tracksNativeShutdown: native) === other)
        }
        #expect(EngineV2Bridge.admittedConstraint(gemma, servesDistributedPair: false,
            tracksNativeShutdown: false) === gemma)
        #expect(EngineV2Bridge.admittedConstraint(nil, servesDistributedPair: true, tracksNativeShutdown: true) == nil)
    }

    @Test func theSwitchReachesTheLaunchdJob() {
        let key = GemmaJSONAnswerPolicy.environmentKey
        #expect(key == "DARKBLOOM_GEMMA_JSON_ANSWERS")
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "off"])[key] == "off")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }
}

/// Client view of one Gemma stream: raw `.content` text passes the service's
/// Gemma 4 channel parser, as it does downstream of the scheduler.
private struct GemmaAnswerOutcome {
    var content = ""
    var contentDeltas: [String] = []
    var reasoning = ""
    var info: ServerGenerationInfo?
    var error: (any Error)?
    private var parser = StreamingReasoningParser(format: .gemma4)

    mutating func record(_ event: MLXServerGenerationEvent) {
        switch event {
        case .content(let text): parser.parse(text).forEach { apply($0) }
        case .parsed(let parsed): apply(parsed)
        case .info(let info): self.info = info
        case .toolCall, .toolCallDelta, .logprobs: break
        }
    }

    mutating func finish() { parser.finish().forEach { apply($0) } }

    private mutating func apply(_ parsed: ParsedReasoning) {
        if !parsed.content.isEmpty {
            content += parsed.content
            contentDeltas.append(parsed.content)
        }
        reasoning += parsed.reasoningContent ?? ""
    }
}

/// Samples a fixed script through the submitted constraint, like a model
/// that honors the masks: the script's next token when allowed; a refused
/// token is skipped, as a sampler moves to the best allowed token; at the
/// script's end an allowed stop. Records each submission.
private final class GemmaScriptedEngine: CBv2Engine, @unchecked Sendable {
    private let script: [Int]
    private let lock = NSLock()
    private var requests: [CBv2Request] = []

    init(script: [Int]) { self.script = script }

    var submitted: [CBv2Request] { lock.withLock { requests } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        if let constraint = request.tokenConstraint, constraint.maxTokens != request.maxTokens {
            throw CBv2SchedulerError.tokenConstraintBudgetMismatch(
                request: request.maxTokens, constraint: constraint.maxTokens)
        }
        lock.withLock { requests.append(request) }
        var tokens: [Int] = []
        var finish = CBv2FinishReason.length
        var state = request.tokenConstraint?.initialState ?? 0
        var remaining = script[...]
        while tokens.count < request.maxTokens {
            let budget = request.maxTokens - tokens.count
            var token: Int?
            if let constraint = request.tokenConstraint {
                let allowed = Set(constraint.allowedTokenIDs(state: state, remainingTokens: budget))
                while let next = remaining.first, !allowed.contains(next) { remaining = remaining.dropFirst() }
                token = remaining.popFirst() ?? allowed.filter(request.stopTokens.contains).min()
                if let token { state = constraint.nextState(state: state, tokenID: token) ?? state }
            } else {
                token = remaining.popFirst() ?? request.stopTokens.min()
            }
            guard let token else { break }
            if request.stopTokens.contains(token) {
                finish = .stop
                break
            }
            tokens.append(token)
        }
        let tokenizer = GemmaPieceTestTokenizer()
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        for token in tokens {
            continuation.yield(.delta(text: tokenizer.decode(tokenIds: [token], skipSpecialTokens: false),
                                      tokens: [token], logprobs: nil))
        }
        continuation.yield(.finished(reason: finish,
            usage: CBv2Usage(promptTokens: request.promptTokens.count, completionTokens: tokens.count)))
        continuation.finish()
        return stream
    }

    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}

@Suite("Gemma JSON answers through the scheduler and bridge")
struct GemmaJSONAnswerServingTests {
    private typealias F = GemmaAnswerFixture
    private let modelID = "gemma-4-26b-qat-4bit"
    private static let tokenizer = TokenizerHandle(GemmaPieceTestTokenizer(), toolConstraintContractVerified: true)

    private func serve(_ engine: GemmaScriptedEngine, fields: String) async throws -> GemmaAnswerOutcome {
        let bridge = EngineV2Bridge(engine: engine, modelId: modelID, tokenizer: Self.tokenizer,
            eosTokenIds: [1, 50, 106], defaultMaxTokens: 64, maxConcurrentRequests: 1)
        let id = modelID
        let tokenizer = Self.tokenizer
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
            [id: .init(tokenizer: tokenizer, modelType: "gemma4", engineV2Bridge: bridge)]
        })
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data("""
        {"model":"\(modelID)","messages":[{"role":"user","content":"hi"}],"reasoning_parser":"gemma4",\(fields)}
        """.utf8))
        var outcome = GemmaAnswerOutcome()
        do {
            for try await event in try await scheduler.streamChatCompletion(request: request) { outcome.record(event) }
        } catch { outcome.error = error }
        outcome.finish()
        await bridge.shutdown()
        return outcome
    }

    private let objectFormat = #""response_format":"# + GemmaAnswerFixture.jsonObject

    @Test func aConstrainedAnswerStreamsWithoutItsFence() async throws {
        // The scripted model wraps its answer in a fence; the masks admit only the value.
        let engine = GemmaScriptedEngine(script: F.pieces("```json") + F.ids("\n{\"a\": [1, \"b\"]}\n") + F.pieces("```"))
        let outcome = try await serve(engine, fields: #""max_tokens":64,"# + objectFormat)
        let constraint = try #require(engine.submitted.first?.tokenConstraint as? GemmaJSONAnswerConstraint)
        #expect(constraint.initialPhase == .answer, "the JSON default renders the closed empty thought")
        #expect(outcome.error == nil && outcome.reasoning.isEmpty)
        #expect(outcome.content == "\n{\"a\": [1, \"b\"]}")
        #expect(outcome.contentDeltas.count > 1, "content streams as generated")
        #expect(outcome.info?.stopReason == "stop")
    }

    @Test func aRequestedThoughtStaysFreeAndTheAnswerFollows() async throws {
        let script = [F.thoughtOpen] + F.ids("thought\nplan {\"draft\":") + [F.thoughtClose] + F.ids("{\"ok\": true}")
        let engine = GemmaScriptedEngine(script: script)
        let outcome = try await serve(engine, fields: #""max_tokens":64,"reasoning":{"enabled":true},"# + objectFormat)
        #expect((engine.submitted.first?.tokenConstraint as? GemmaJSONAnswerConstraint)?.initialPhase == .opening)
        #expect(outcome.error == nil)
        #expect(outcome.reasoning == "plan {\"draft\":")
        #expect(outcome.content == "{\"ok\": true}")
    }

    @Test func aSchemaAnswerKeepsOnlyDeclaredKeys() async throws {
        let schema = #""response_format":"# + F.schemaFormat(F.schema)
        // The scripted model adds an undeclared key; the masks skip it.
        let engine = GemmaScriptedEngine(script: F.ids(#"{"name": "Rex", "zz": 1, "owner": {"id": 7}}"#))
        let outcome = try await serve(engine, fields: #""max_tokens":96,"# + schema)
        #expect(outcome.error == nil && outcome.info?.stopReason == "stop")
        #expect(outcome.content == #"{"name": "Rex", "owner": {"id": 7}}"#)
    }

    @Test func aBudgetCutStaysLengthWithoutAnError() async throws {
        let engine = GemmaScriptedEngine(script: F.ids(#"{"a": "a long answer"}"#))
        let outcome = try await serve(engine, fields: #""max_tokens":6,"# + objectFormat)
        #expect(outcome.error == nil, "unlike Qwen's validated answers, a cut is not a refusal")
        #expect(outcome.content == #"{"a": "#)
        #expect(outcome.info?.stopReason == "length")
    }

    @Test func requestsWithoutAJSONFormatAreUnconstrained() async throws {
        let engine = GemmaScriptedEngine(script: F.ids("plain text"))
        let outcome = try await serve(engine, fields: #""max_tokens":64"#)
        #expect(engine.submitted.first?.tokenConstraint == nil)
        #expect(outcome.content == "plain text")
    }
}
