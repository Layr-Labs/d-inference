// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// Red control: the call parser's literal reading is not modelled yet.
enum QwenParserLiteralReading {
    static func literal(_ text: String, schema: [String: MLXLMCommon.JSONValue]) -> MLXLMCommon.JSONValue? { nil }

    static func admitsLiteralType(_ schema: [String: MLXLMCommon.JSONValue]) -> Bool { false }

    static func canonicalType(_ name: String) -> String? {
        let type = name.lowercased()
        switch type {
        case "string", "str", "text", "varchar", "char", "enum": return "string"
        case "integer", "int", "uint", "long", "short", "unsigned": return "integer"
        case "number", "float": return "number"
        case "boolean", "bool", "binary": return "boolean"
        case "object", "dict": return "object"
        case "array", "arr", "list": return "array"
        case "null": return "null"
        default:
            if ["int", "uint", "long", "short", "unsigned"].contains(where: type.hasPrefix) { return "integer" }
            if type.hasPrefix("num") || type.hasPrefix("float") { return "number" }
            if type.hasPrefix("dict") { return "object" }
            if type.hasPrefix("list") { return "array" }
            return nil
        }
    }
}
