import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

@Suite("Qwen JSON answers for client schemas outside the subset")
struct QwenJSONSchemaRewriteTests {
    private typealias F = QwenAnswerFixture
    private static let handle = TokenizerHandle(QwenByteTestTokenizer())
    private static let prompt = QwenByteTestTokenizer.tokens(QwenByteTestTokenizer.prompt(thinking: false))

    /// Pydantic's shape: nested models in `$defs`, an enum class, an
    /// `Optional` as `anyOf` with null.
    static let pydantic = ##"""
    {"$defs":{"Address":{"properties":{"street":{"title":"Street","type":"string"},"city":{"title":"City","type":"string"}},
      "required":["street","city"],"title":"Address","type":"object","additionalProperties":false},
      "Status":{"enum":["new","shipped"],"title":"Status","type":"string"}},
     "properties":{"name":{"title":"Name","type":"string"},"address":{"$ref":"#/$defs/Address"},
      "status":{"$ref":"#/$defs/Status"},
      "nickname":{"anyOf":[{"type":"string"},{"type":"null"}],"default":null,"title":"Nickname"}},
     "required":["name","address","status","nickname"],"title":"Person","type":"object","additionalProperties":false}
    """##
    /// Value assertions the subset cannot spell, as Pydantic and zod write them.
    static let assertions = #"""
    {"type":"object","properties":{
      "age":{"type":"integer","minimum":0,"maximum":150},
      "email":{"type":"string","format":"email","maxLength":64,"pattern":"^[^@]+@[^@]+$"},
      "scores":{"type":"object","additionalProperties":{"type":"number","exclusiveMinimum":0}},
      "tags":{"type":"array","items":{"type":"string","minLength":1},"maxItems":64,"uniqueItems":true}},
     "required":["age","email"],"additionalProperties":false}
    """#

    private func make(_ format: String, widens: Bool = true, model: String? = nil,
                      modelType: String = "qwen3_5", stops: Set<Int> = F.stops) throws -> JSONAnswerConstraint? {
        var request = try F.request(format: format)
        if let model { request.model = model }
        return JSONAnswerPolicy.constraint(request: request, tokenizer: Self.handle, modelID: request.model,
            modelType: modelType, defaultMaxTokens: 100, stopTokenIDs: stops, promptTokens: Self.prompt,
            servesDistributedPair: false, families: .all, widensSchemas: widens)
    }

    private static func json(_ text: String) throws -> MLXLMCommon.JSONValue {
        try JSONDecoder().decode(MLXLMCommon.JSONValue.self, from: Data(text.utf8))
    }

    private func ends(_ text: String, _ constraint: JSONAnswerConstraint) -> Bool {
        guard let state = F.walk(text, constraint) else { return false }
        return constraint.allowedTokenIDs(state: state, remainingTokens: 10).contains(F.imEnd)
    }

    @Test func pydanticSchemasAreEnforcedAsWritten() throws {
        let constraint = try #require(try make(F.schemaFormat(Self.pydantic)))
        #expect(constraint.format.schema != nil && constraint.format.family == "Qwen")
        for nickname in ["null", #""Sofi""#] {
            #expect(ends(#"{"address":{"city":"B","street":"C"},"name":"S","nickname":"# + nickname
                + #","status":"new"}"#, constraint), "\(nickname)")
        }
        #expect(F.walk(#"{"address":{"city":"B"}}"#, constraint) == nil, "street is required")
        #expect(F.walk(#"{"address":{"city":"B","street":"C"},"name":"S","nickname":null,"status":"o"#,
                       constraint) == nil, "status is an enum")
        #expect(F.walk("```", constraint) == nil, "no fence")
        // The switch off declines it, as today.
        #expect(try make(F.schemaFormat(Self.pydantic), widens: false) == nil)
    }

    @Test func valueAssertionsLeaveTheStructureEnforcedAndTheValuesFree() throws {
        let constraint = try #require(try make(F.schemaFormat(Self.assertions)))
        #expect(constraint.format.schema != nil)
        let answer = #"{"age":-5,"email":"not an email","scores":{"a":-1.5},"tags":["","",""]}"#
        #expect(ends(answer, constraint))
        #expect(F.walk(#"{"age":"x"#, constraint) == nil, "types stay")
        #expect(F.walk(#"{"age":1,"email":"e","extra""#, constraint) == nil, "additionalProperties false stays")
        // Never a refusal for a value the grammar left free.
        #expect(throws: Never.self) { try constraint.format.validate(content: answer, finishReason: "stop") }
        for schema in [#"{"type":"string","pattern":"^a"}"#, #"{"type":"array","items":{"type":"string"},"maxItems":64}"#] {
            let relaxed = try #require(try make(F.schemaFormat(schema)), "\(schema)")
            #expect(relaxed.format.schema != nil)
            #expect(try make(F.schemaFormat(schema), widens: false) == nil, "\(schema)")
        }
        #expect(try make(F.schemaFormat(Self.assertions), widens: false) == nil)
    }

    @Test func objectSchemasTheSubsetCannotShapeAreHeldToAJSONObject() throws {
        let union = #"{"type":"object","properties":{"id":{"anyOf":[{"type":"string"},{"type":"integer"}]}}}"#
        let constraint = try #require(try make(F.schemaFormat(union)))
        #expect(constraint.format.schema == nil, "a JSON object")
        #expect(ends(#"{"id":1}"#, constraint) && ends(#"{"anything":["x"]}"#, constraint))
        #expect(F.walk("[", constraint) == nil && F.walk("```", constraint) == nil)
        #expect(try make(F.schemaFormat(union), widens: false) == nil)
        // Other roots stay prompt-only.
        for schema in [#"{"anyOf":[{"type":"string"},{"type":"integer"}]}"#, #"{"type":"string","enum":["<think>"]}"#,
                       ##"{"$ref":"#/$defs/A","type":"object","$defs":{"A":{"anyOf":[{"type":"string"},{"type":"integer"}]}}}"##] {
            #expect(try make(F.schemaFormat(schema)) == nil, "\(schema)")
        }
    }

    @Test func onlyQwenWidens() throws {
        // Bonsai shares Qwen's tokenizer and policy; it keeps declining these.
        let bonsai = "ternary-bonsai-2-27b"
        #expect(try make(F.schemaFormat(F.schema), model: bonsai, modelType: "prism_hadamard_qwen35",
                         stops: [F.imEnd]) != nil)
        #expect(try make(F.schemaFormat(Self.pydantic), model: bonsai, modelType: "prism_hadamard_qwen35",
                         stops: [F.imEnd]) == nil)
        for type in ["qwen3_5", "qwen3_5_moe"] {
            #expect(try make(F.schemaFormat(Self.pydantic), modelType: type) != nil, "\(type)")
        }
    }

    @Test func theRelaxedRewriteDropsOnlyValueAssertions() throws {
        let cases = [
            (#"{"type":"string","pattern":"^a","format":"email","minLength":1,"maxLength":5}"#, #"{"type":"string"}"#),
            (#"{"type":"integer","minimum":0,"exclusiveMaximum":10,"multipleOf":2}"#, #"{"type":"integer"}"#),
            (#"{"type":"array","items":{"type":"string"},"minItems":20,"maxItems":64,"uniqueItems":true}"#,
             #"{"type":"array","items":{"type":"string"}}"#),
            (#"{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":3}"#,
             #"{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":3}"#),
            (#"{"type":"object","additionalProperties":{"type":"integer"},"minProperties":1,"propertyNames":{"pattern":"^a"}}"#,
             #"{"type":"object","additionalProperties":true}"#),
            (##"{"$ref":"#/$defs/A","minimum":1,"$defs":{"A":{"type":"integer","maximum":3}}}"##, #"{"type":"integer"}"#),
            (#"{"anyOf":[{"type":"string","maxLength":3},{"type":"null"}]}"#, #"{"type":"string","nullable":true}"#),
            // Structure is never dropped: the compiler still refuses these.
            (#"{"type":"object","patternProperties":{"^a":{"type":"string"}}}"#,
             #"{"type":"object","patternProperties":{"^a":{"type":"string"}}}"#),
        ]
        for (input, expected) in cases {
            #expect(ResponseSchemaRewrite.subset(try Self.json(input), relaxingAssertions: true) == (try Self.json(expected)),
                    "\(input)")
        }
        // The exact rewrite keeps every assertion.
        let pattern = try Self.json(#"{"type":"string","pattern":"^a"}"#)
        #expect(ResponseSchemaRewrite.subset(pattern) == pattern)
    }

    @Test func theSwitchReachesTheLaunchdJobAndReadsOffWords() {
        let key = QwenJSONSchemaRewrite.environmentKey
        #expect(key == "DARKBLOOM_QWEN_JSON_SCHEMA_REWRITE")
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "off"])[key] == "off")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
        for value in [nil, "", "on", "1", "yes"] as [String?] { #expect(QwenJSONSchemaRewrite.isEnabled(value)) }
        for value in ["off", "0", "false", "no", " OFF "] { #expect(!QwenJSONSchemaRewrite.isEnabled(value)) }
    }
}
