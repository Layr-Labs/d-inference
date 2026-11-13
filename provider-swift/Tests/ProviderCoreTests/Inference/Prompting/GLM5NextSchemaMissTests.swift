import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// `DARKBLOOM_GLM_JSON_SCHEMA_MISS`: a GLM JSON answer that parses but misses
/// its schema is the typed 422 by default, or with `release` the normalized
/// answer, for the caller's own validator to judge. Non-JSON stays a 422.
@Suite("GLM JSON schema-miss switch")
struct GLM5NextSchemaMissTests {
    static var weather: [String: Any] { [
        "type": "object",
        "properties": ["city": ["type": "string"], "temperature_f": ["type": "integer"],
                       "conditions": ["type": "string", "enum": ["sunny", "rain"]]] as [String: Any],
        "required": ["city", "temperature_f", "conditions"],
        "additionalProperties": false,
    ] }
    /// `minimum` alone keeps the schema inside the compiled subset; `not` takes it outside, so the
    /// raw-schema validator judges it.
    static var outsideSubset: [String: Any] { [
        "type": "object", "properties": ["n": ["type": "integer", "not": ["const": 3]]] as [String: Any],
        "required": ["n"],
    ] }

    static func format(_ responseFormat: [String: Any], schemaMiss: GLM5NextSchemaMiss) throws
        -> GLM5NextResponseFormat {
        let body: [String: Any] = ["model": "glm-5.3-flash", "messages": [["role": "user", "content": "Weather?"]],
                                   "response_format": responseFormat]
        let request = try ProviderLoop.decodeOpenAIRequest(JSONSerialization.data(withJSONObject: body),
            modelType: "glm5_next")
        let resolved = try #require(try GLM5NextResponseFormat.resolve(request, modelType: "glm5_next"))
        return GLM5NextResponseFormat(format: resolved.format, schema: resolved.schema,
            rawSchema: resolved.rawSchema, schemaMiss: schemaMiss)
    }

    static func schemaFormat(_ schema: [String: Any]) -> [String: Any] {
        ["type": "json_schema", "json_schema": ["name": "w", "strict": true, "schema": schema] as [String: Any]]
    }

    @Test("the switch is refuse unless it reads release")
    func switchParsing() {
        for value in [nil, "", "refuse", "off", "0", "releases"] as [String?] {
            #expect(GLM5NextSchemaMiss.parse(value) == .refuse)
        }
        for value in ["release", " RELEASE ", "Release"] { #expect(GLM5NextSchemaMiss.parse(value) == .release) }
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(GLM5NextSchemaMiss.environmentKey))
    }

    @Test("refuse keeps the typed 422 for a schema miss", arguments: [
        #"{"city":"PRIVATE","temperature_f":75,"conditions":"hot"}"#,
        #"{"city":"PRIVATE","temperature_f":75,"conditions":"sunny","extra":1}"#,
    ])
    func refuseKeepsThe422(answer: String) throws {
        let format = try Self.format(Self.schemaFormat(Self.weather), schemaMiss: .refuse)
        #expect(throws: MLXOpenAIServiceError.self) { try format.validatedContent(answer, finishReason: "stop") }
    }

    @Test("release exposes a schema miss as the normalized JSON", arguments: [
        (#"{"city":"Austin","temperature_f":75,"conditions":"hot"}"#,
         #"{"city":"Austin","temperature_f":75,"conditions":"hot"}"#),
        ("```json\n{\"city\":\"Austin\",\"temperature_f\":75.5,\"conditions\":\"sunny\"}\n```",
         #"{"city":"Austin","temperature_f":75.5,"conditions":"sunny"}"#),
        ("Here it is: {\"city\":\"Austin\"} Hope that helps.", #"{"city":"Austin"}"#),
    ])
    func releaseExposesTheNormalizedAnswer(answer: String, normalized: String) throws {
        let format = try Self.format(Self.schemaFormat(Self.weather), schemaMiss: .release)
        #expect(try format.validatedContent(answer, finishReason: "stop") == normalized)
        var output = GLM5NextResponseFormatOutput(format)
        #expect(output.withholding(.content(answer)) == nil)
        let event = try output.finalAnswer(finishReason: "stop", hasToolCalls: false)
        guard case .parsed(let parsed)? = event else { Issue.record("no answer event"); return }
        #expect(parsed.content == normalized && parsed.reasoningContent == nil)
    }

    @Test("release covers a schema outside the compiled subset too")
    func releaseCoversRawSchemas() throws {
        let format = try Self.format(Self.schemaFormat(Self.outsideSubset), schemaMiss: .release)
        #expect(format.schema == nil && format.rawSchema != nil)
        #expect(try format.validatedContent(#"{"n":3}"#, finishReason: "stop") == #"{"n":3}"#)
        let refused = try Self.format(Self.schemaFormat(Self.outsideSubset), schemaMiss: .refuse)
        #expect(throws: MLXOpenAIServiceError.self) { try refused.validatedContent(#"{"n":3}"#, finishReason: "stop") }
    }

    @Test("release still refuses what is not a complete JSON answer", arguments: [
        ("PRIVATE: it is sunny in Austin.", "stop", "json_schema"),
        (#"{"city":"PRIVATE","temp"#, "length", "json_schema"),
        ("[\"PRIVATE\"]", "stop", "json_object"),
        ("PRIVATE prose", "stop", "json_object"),
    ])
    func releaseStillRefusesNonJSON(answer: String, finish: String, kind: String) throws {
        let responseFormat = kind == "json_object" ? ["type": "json_object"] : Self.schemaFormat(Self.weather)
        let format = try Self.format(responseFormat, schemaMiss: .release)
        #expect(throws: MLXOpenAIServiceError.self) { try format.validatedContent(answer, finishReason: finish) }
    }

    @Test("a truncated root number is refused in both modes")
    func truncatedNumberIsRefused() throws {
        let numberSchema = Self.schemaFormat(["type": "integer"])
        for mode in [GLM5NextSchemaMiss.refuse, .release] {
            let format = try Self.format(numberSchema, schemaMiss: mode)
            #expect(throws: MLXOpenAIServiceError.self) { try format.validatedContent("12", finishReason: "length") }
        }
    }
}
