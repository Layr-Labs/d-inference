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

    @Test func limitsAndIdentifierRollback() throws {
        typealias Compiler = ToolConstraintSchemaCompiler
        let off = Compiler.PropertyNames(environmentValue: " OFF ")
        #expect(off == .identifiers)
        for key in ["", String(repeating: "é", count: 128) + "a"] {
            #expect(throws: ToolConstraintSchemaError.self) { try Compiler.compileResponseSchema(schema(key)) }
        }
        #expect(throws: ToolConstraintSchemaError.self) {
            try Compiler.compileResponseSchema(schema("first name"), propertyNames: off)
        }
        let compiled = try Compiler.compileResponseSchema(schema("before<think>after"))
        #expect(throws: ToolConstraintSchemaError.self) {
            try FlintJSONGrammar(schema: compiled, forbidding: [Array("<think>".utf8)], family: "test")
        }
    }

    @Test func canonicalEquivalenceDoesNotRenameAProperty() throws {
        let compiled = try ToolConstraintSchemaCompiler.compileResponseSchema(schema("é"))
        #expect(ToolConstraintValidation.satisfies(.object(["é": .int(1)]), schema: compiled))
        #expect(!ToolConstraintValidation.satisfies(.object(["e\u{301}": .int(1)]), schema: compiled))
    }

    @Test func identifierKeysHaveIdenticalAllowedBytesAtEveryPrefix() throws {
        typealias Compiler = ToolConstraintSchemaCompiler
        let key = String(repeating: "A_x-9", count: 12) + "abcd"
        let old = try FlintJSONGrammar(schema: Compiler.compileResponseSchema(schema(key), propertyNames: .identifiers),
                                       forbidding: [], family: "test")
        let new = try FlintJSONGrammar(schema: Compiler.compileResponseSchema(schema(key), propertyNames: .json),
                                       forbidding: [], family: "test")
        var before = FlintJSONState(grammar: old), after = FlintJSONState(grammar: new)
        for (offset, byte) in "{\"\(key)\":1}".utf8.enumerated() {
            let a = (UInt8.min...UInt8.max).filter { var s = before; return s.consume($0, grammar: old) }
            let b = (UInt8.min...UInt8.max).filter { var s = after; return s.consume($0, grammar: new) }
            #expect(a == b)
            // The identifier-only automaton admitted just the next literal
            // byte from the opening quote up to and including the closing one.
            if (2...(key.utf8.count + 2)).contains(offset) { #expect(b == [byte]) }
            let acceptedBefore = before.consume(byte, grammar: old)
            let acceptedAfter = after.consume(byte, grammar: new)
            #expect(acceptedBefore && acceptedAfter)
        }
        #expect(before.isComplete(old) && after.isComplete(new))
    }
}
