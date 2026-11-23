import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Declared JSON response keys")
struct ResponsePropertyNameTests {
    private func schema(_ name: String) -> MLXLMCommon.JSONValue {
        .object(["type": .string("object"), "properties": .object([name: .object(["type": .string("integer")])]),
                 "required": .array([.string(name)]), "additionalProperties": .bool(false)])
    }

    private func accepts(_ text: String, _ grammar: FlintJSONGrammar) -> Bool {
        var state = FlintJSONState(grammar: grammar)
        for byte in text.utf8 where !state.consume(byte, grammar: grammar) { return false }
        return state.isComplete(grammar)
    }

    @Test func exactSpellingOnly() throws {
        for (name, spelling) in [
            ("first name", "first name"), ("user.email", "user.email"), ("a:b/c", "a:b/c"),
            ("名前", "名前"), (String(repeating: "a", count: 68), String(repeating: "a", count: 68)),
            ("q\"\\", #"q\"\\"#), ("a\nb", #"a\u000ab"#),
            (String(repeating: "é", count: 128), String(repeating: "é", count: 128))
        ] {
            let compiled = try ToolConstraintSchemaCompiler.compileResponseSchema(schema(name))
            let grammar = try FlintJSONGrammar(schema: compiled, forbidding: [], family: "test")
            let member = "\"\(spelling)\":1"
            #expect(accepts("{\(member)}", grammar))
            #expect(!accepts("{\(member),\(member)}", grammar))
            #expect(!accepts("{}", grammar))
        }
        let compiled = try ToolConstraintSchemaCompiler.compileResponseSchema(schema("a/b"))
        let grammar = try FlintJSONGrammar(schema: compiled, forbidding: [], family: "test")
        #expect(!accepts(#"{"a\/b":1}"#, grammar))
        #expect(!accepts(#"{"a/b":1,"\u0061/b":1}"#, grammar))
    }
}
