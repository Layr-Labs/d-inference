// Copyright © 2026 Eigen Labs.

import Foundation
import Jinja

/// Hugging Face-compatible filters for the Nemotron chat template.
///
/// The pinned template renders JSON-schema metadata with `string` and
/// `tojson`. Swift-Jinja's defaults intentionally follow Swift/Foundation,
/// while Transformers uses Python `str` and `json.dumps(ensure_ascii=False)`.
/// Keep this compatibility layer model-scoped so other families retain their
/// existing prompt bytes until independently qualified.
public enum NemotronTemplateFilters {
    private static let outputLimit = 16 << 20

    public static func applies(modelType: String?) -> Bool {
        modelType?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "nemotron_h"
    }

    public static func additionalContext(modelType: String?) -> [String: any Sendable]? {
        guard applies(modelType: modelType) else { return nil }
        return [
            stringFilterName: stringFilter,
            "tojson": toJSONFilter,
        ]
    }

    public static func install(in environment: Environment, modelType: String?) {
        guard applies(modelType: modelType) else { return }
        environment[stringFilterName] = stringFilter
        environment["tojson"] = toJSONFilter
    }

    private static let stringFilter = Value.function { args, kwargs, _ in
        let value = try soleDefaultArgument(args, kwargs)
        switch value {
        case .boolean(let flag): return .string(flag ? "True" : "False")
        case .null: return .string("None")
        case .undefined: return .string("")
        default: return .string(value.description)
        }
    }

    private static let toJSONFilter = Value.function { args, kwargs, _ in
        let value = try soleDefaultArgument(args, kwargs)
        var writer = PythonJSONWriter(limit: outputLimit)
        try writer.write(value)
        return .string(try writer.string())
    }

    private static func soleDefaultArgument(
        _ args: [Value], _ kwargs: [String: Value]
    ) throws -> Value {
        guard args.count == 1, kwargs.isEmpty else {
            throw JinjaError.runtime(
                "Nemotron reference filters only support their pinned default arguments")
        }
        return args[0]
    }

    private struct PythonJSONWriter {
        private var bytes = Data()
        private let limit: Int

        init(limit: Int) {
            self.limit = limit
            bytes.reserveCapacity(min(limit, 4096))
        }

        mutating func write(_ value: Value, depth: Int = 0) throws {
            guard depth <= 128 else {
                throw JinjaError.runtime("Nemotron prompt JSON nesting exceeds its bound")
            }
            switch value {
            case .null, .undefined:
                try append("null")
            case .boolean(let flag):
                try append(flag ? "true" : "false")
            case .int(let number):
                try append(String(number))
            case .double(let number):
                guard number.isFinite else {
                    throw JinjaError.runtime("Nemotron prompt JSON contains a nonfinite number")
                }
                try append(String(number))
            case .string(let text):
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.withoutEscapingSlashes]
                try append(encoder.encode(text))
            case .array(let values):
                try append("[")
                for (index, item) in values.enumerated() {
                    if index > 0 { try append(", ") }
                    try write(item, depth: depth + 1)
                }
                try append("]")
            case .object(let values):
                try append("{")
                for (index, pair) in values.enumerated() {
                    if index > 0 { try append(", ") }
                    try write(.string(pair.key), depth: depth + 1)
                    try append(": ")
                    try write(pair.value, depth: depth + 1)
                }
                try append("}")
            case .function, .macro:
                throw JinjaError.runtime("Nemotron prompt JSON contains an unsupported value")
            }
        }

        mutating func append(_ text: String) throws {
            try append(Data(text.utf8))
        }

        mutating func append(_ value: Data) throws {
            guard bytes.count <= limit - value.count else {
                throw JinjaError.runtime("Nemotron prompt JSON exceeds its byte bound")
            }
            bytes.append(value)
        }

        func string() throws -> String {
            guard let value = String(data: bytes, encoding: .utf8) else {
                throw JinjaError.runtime("Nemotron prompt JSON is not UTF-8")
            }
            return value
        }
    }
}
