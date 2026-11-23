import CryptoKit
import Foundation
import MLXLMCommon
import MLXLMServer
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
            let compiled = try ToolConstraintSchemaCompiler.compileResponseSchema(schema(name), propertyNames: .json)
            let grammar = try FlintJSONGrammar(schema: compiled, forbidding: [], family: "test")
            let member = "\"\(spelling)\":1"
            #expect(accepts("{\(member)}", grammar))
            #expect(!accepts("{\(member),\(member)}", grammar))
            #expect(!accepts("{}", grammar))
        }
        let compiled = try ToolConstraintSchemaCompiler.compileResponseSchema(schema("a/b"), propertyNames: .json)
        let grammar = try FlintJSONGrammar(schema: compiled, forbidding: [], family: "test")
        #expect(!accepts(#"{"a\/b":1}"#, grammar))
        #expect(!accepts(#"{"a/b":1,"\u0061/b":1}"#, grammar))
    }

    @Test func limitsAndIdentifierRollback() throws {
        typealias Compiler = ToolConstraintSchemaCompiler
        let off = Compiler.PropertyNames(environmentValue: " OFF ")
        for value: String? in [nil, "", "unknown", "0", "off", "false", "no"] {
            #expect(Compiler.PropertyNames(environmentValue: value) == .identifiers)
        }
        for value in ["1", " On ", "true", "yes"] {
            #expect(Compiler.PropertyNames(environmentValue: value) == .json)
        }
        for key in ["", String(repeating: "é", count: 128) + "a"] {
            #expect(throws: ToolConstraintSchemaError.self) { try Compiler.compileResponseSchema(schema(key), propertyNames: .json) }
        }
        #expect(throws: ToolConstraintSchemaError.self) {
            try Compiler.compileResponseSchema(schema("first name"), propertyNames: off)
        }
        let compiled = try Compiler.compileResponseSchema(schema("before<think>after"), propertyNames: .json)
        #expect(throws: ToolConstraintSchemaError.self) {
            try FlintJSONGrammar(schema: compiled, forbidding: [Array("<think>".utf8)], family: "test")
        }
    }

    @Test func canonicalEquivalenceDoesNotRenameAProperty() throws {
        let compiled = try ToolConstraintSchemaCompiler.compileResponseSchema(schema("é"), propertyNames: .json)
        #expect(ToolConstraintValidation.satisfies(.object(["é": .int(1)]), schema: compiled, propertyNames: .json))
        #expect(!ToolConstraintValidation.satisfies(.object(["e\u{301}": .int(1)]), schema: compiled, propertyNames: .json))
    }

    @Test func exactCheckedAnswerAndUnchangedForcedToolPath() throws {
        let key = "field with space"
        let format = OpenAIResponseFormat.jsonSchema(.init(name: "example", strict: true, schema: schema(key)))
        let answer = try #require(QwenJSONSchemaRewrite.answerFormat(format, profile: .qwen35, widens: true, propertyNames: .json))
        #expect(answer.widening == nil && answer.format.checksOutput)
        try answer.format.validate(content: #"{"field with space":1}"#, finishReason: "stop")
        #expect(throws: (any Error).self) {
            try answer.format.validate(content: #"{"field_with_space":1}"#, finishReason: "stop")
        }
        let tool = OpenAITool(type: "function", function: .init(name: "lookup", parameters: schema(key)))
        #expect(throws: ToolConstraintSchemaError.self) {
            try ToolConstraintSchemaCompiler.compile(tools: [tool], mode: .required)
        }
    }

    @Test func nestedDiagnosticOmitsExpandedKeyText() throws {
        let raw: MLXLMCommon.JSONValue = .object(["type": .string("object"), "properties": .object([
            "synthetic\nfield": .object(["type": .string("object"), "required": .bool(false)])
        ])])
        do {
            _ = try ToolConstraintSchemaCompiler.compileResponseSchema(raw, propertyNames: .json)
            Issue.record("accepted a malformed required list")
        } catch let ToolConstraintSchemaError.invalid(detail) {
            #expect(detail == "json_schema.schema.properties[].required must be an array")
        }
    }

    @Test func identifierMasksMatchThePreChangeGrammar() throws {
        // Golden from dc25f81861: 256 next-byte decisions at each of 299 prefixes.
        let k = String(repeating: "x", count: 64)
        let value = ToolValueSchema.integer(values: nil, nullable: false)
        let keys = ["n", "n1", "n_2", k]
        let child = ToolValueSchema.object(properties: [.init(name: "n", schema: value, required: true),
                                                         .init(name: "n1", schema: value, required: false)],
                                            allowsAdditional: false, nullable: false)
        let object = ToolValueSchema.object(properties: keys.map { .init(name: $0, schema: $0 == "n" ? child : value, required: $0 != "n1") },
                                            allowsAdditional: false, nullable: false)
        let g = try FlintJSONGrammar(schema: object, forbidding: [], family: "test")
        var prefixes = 0, masks = Data()
        for order in [keys, Array(keys.reversed()), [keys[2],keys[0],keys[3]]] {
            let answer = "{" + order.map { key in
                let v = key == "n" ? (order.first == "n" ? #"{"n":1,"n1":2}"# : #"{"n":1}"#) : "42"
                return "\"\(key)\":\(v)"
            }.joined(separator: ",") + "}"
            var state = FlintJSONState(grammar: g)
            for b in answer.utf8 {
                for candidate in UInt8.min...UInt8.max {
                    var trial = state
                    masks.append(trial.consume(candidate, grammar: g) ? 1 : 0)
                }
                precondition(state.consume(b, grammar: g))
                prefixes += 1
            }
            precondition(state.isComplete(g))
        }
        #expect(prefixes == 299)
        let digest = SHA256.hash(data: masks).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "d70c86e564089e3aadc800e650d83ab9b657f6d6add3cc33b9024b65f5614a98")
    }
}
