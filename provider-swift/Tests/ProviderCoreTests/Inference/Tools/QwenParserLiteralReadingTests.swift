import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// `QwenParserLiteralReading` against the call parser itself: under schemas
/// the parser reads as text, a text becomes exactly the literal the mirror
/// names, and every other text stays as written.
@Suite("Qwen parser literal reading")
struct QwenParserLiteralReadingTests {
    static let schemas = [
        #"{"not":{"type":"string"}}"#,
        #"{"if":{"type":"integer"},"then":{"type":"integer","minimum":-100000000},"else":{"type":"string"}}"#,
        #"{"type":["string","integer"]}"#, #"{"anyOf":[{"type":"string"},{"type":"number"}]}"#,
        #"{"anyOf":[{"type":"integer","minimum":0},{"type":"string"}]}"#, "{}", #"{"description":"untyped"}"#,
        #"{"type":["boolean","string"]}"#, #"{"type":["null","string"]}"#, #"{"not":{"type":"integer"}}"#,
        #"{"type":"string"}"#, #"{"enum":["5","a"]}"#, #"{"const":5}"#, #"{"enum":[true,"x"]}"#,
        #"{"not":{"type":"string"},"multipleOf":5}"#, #"{"type":"string","nullable":true}"#,
        #"{"oneOf":[{"type":"string"},{"type":"integer"},{"type":"number"}]}"#,
        #"{"type":["string","null"]}"#, #"{"anyOf":[{"type":"string"},{"type":"boolean"}]}"#,
        #"{"type":["string","integer"],"nullable":true}"#,
        #"{"anyOf":[{"type":"string"},{"type":"integer"}],"type":"string"}"#,
        #"{"anyOf":[{"type":"string"},{"type":"boolean"}],"type":"string"}"#,
        #"{"oneOf":[{"type":"string"},{"type":"number"}],"type":"string"}"#,
        #"{"type":"string","nullable":true}"#,
        #"{"enum":["default","inherit","archive",-1],"type":"string"}"#, #"{"not":{"type":"string"},"type":"string"}"#,
        #"{"if":{"type":"integer"},"then":{"type":"integer","minimum":-100000000},"else":{"type":"string"},"type":"string"}"#,
        #"{"type":"string","anyOf":[{"minLength":1},{"pattern":"^a"}]}"#,
        #"{"type":"integer","nullable":true,"anyOf":[{"type":"integer"},{"type":"string"},{"type":"null"}]}"#,
    ]
    static let probes = [
        "5", "2.5", "-2500", "true", "false", "null", "001", "+5", "1e3", "-0", "12.50", "abc", " 5", "15",
        "True", "False", "None", "TRUE", "nil", " null", "NULL", "none", "yes", "archive", "-1",
        "12345678901234567890", "0.12345678901234567891", #"{"a":1,"b":[true,null]}"#, "[1,2.5]",
        #"{"n":12345678901234567890}"#, #"{"a":"#, "{}", "[]",
    ]

    /// A schema as a request's tool map carries it.
    static func sendable(_ value: MLXLMCommon.JSONValue) -> any Sendable {
        switch value {
        case .null: NSNull()
        case .bool(let bool): bool
        case .int(let int): int
        case .double(let double): double
        case .string(let string): string
        case .array(let items): items.map(sendable)
        case .object(let members): members.mapValues(sendable)
        }
    }

    @Test func theMirrorReadsLiteralsAsTheCallParserDoes() throws {
        let parser = Qwen35ToolCallParser(startTag: "<tool_call>", endTag: "</tool_call>")
        var literals = 0
        for raw in Self.schemas {
            guard case .object(let schema) = try JSONDecoder().decode(MLXLMCommon.JSONValue.self, from: Data(raw.utf8)) else {
                Issue.record("not a schema object: \(raw)")
                continue
            }
            let tools: [[String: any Sendable]] = [[
                "type": "function",
                "function": [
                    "name": "f",
                    "parameters": ["type": "object", "properties": ["v": Self.sendable(.object(schema))]]
                        as [String: any Sendable],
                ] as [String: any Sendable],
            ]]
            for text in Self.probes {
                let frame = "<tool_call>\n<function=f>\n<parameter=v>\n\(text)\n</parameter>\n</function>\n</tool_call>"
                let value = try #require(parser.parse(content: frame, tools: tools)?.function.arguments["v"])
                let literal = QwenParserLiteralReading.literal(text, schema: schema)
                if literal != nil { literals += 1 }
                #expect(value == (literal ?? .string(text)), "\(raw) reading \(text): \(value)")
            }
        }
        #expect(literals > 20)
    }

    /// The type-level answer agrees with the per-text one: a schema under
    /// which no text reads as a literal says so.
    @Test func admittingNoLiteralTypeReadsNoLiteral() throws {
        for raw in Self.schemas {
            guard case .object(let schema) = try JSONDecoder().decode(MLXLMCommon.JSONValue.self, from: Data(raw.utf8)) else {
                continue
            }
            if !QwenParserLiteralReading.admitsLiteralType(schema) {
                for text in Self.probes {
                    #expect(QwenParserLiteralReading.literal(text, schema: schema) == nil, "\(raw) \(text)")
                }
            }
        }
    }
}
