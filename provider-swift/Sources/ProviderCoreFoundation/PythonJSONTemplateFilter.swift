// Copyright © 2026 Eigen Labs.

import Foundation
import Jinja

/// `tojson` as Transformers renders it for a chat template: Python
/// `json.dumps(value, ensure_ascii=False)` with its default separators.
/// Swift-Jinja's own filter follows Foundation instead (compact separators,
/// escaped non-ASCII text and slashes). A family opts in through its own
/// filter set, so every other template keeps its existing prompt bytes.
enum PythonJSONTemplateFilter {
    /// `family` names the model family in thrown errors.
    static func make(family: String, outputLimit: Int) -> Value {
        .function { args, kwargs, _ in
            guard args.count == 1, kwargs.isEmpty else {
                throw JinjaError.runtime(
                    "\(family) reference filters only support their pinned default arguments")
            }
            var writer = Writer(family: family, limit: outputLimit)
            try writer.write(args[0])
            return .string(try writer.string())
        }
    }

    private struct Writer {
        private var bytes = Data()
        private let family: String
        private let limit: Int

        init(family: String, limit: Int) {
            self.family = family
            self.limit = limit
            bytes.reserveCapacity(min(limit, 4096))
        }

        mutating func write(_ value: Value, depth: Int = 0) throws {
            guard depth <= 128 else {
                throw JinjaError.runtime("\(family) prompt JSON nesting exceeds its bound")
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
                    throw JinjaError.runtime("\(family) prompt JSON contains a nonfinite number")
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
                throw JinjaError.runtime("\(family) prompt JSON contains an unsupported value")
            }
        }

        mutating func append(_ text: String) throws {
            try append(Data(text.utf8))
        }

        mutating func append(_ value: Data) throws {
            guard bytes.count <= limit - value.count else {
                throw JinjaError.runtime("\(family) prompt JSON exceeds its byte bound")
            }
            bytes.append(value)
        }

        func string() throws -> String {
            guard let value = String(data: bytes, encoding: .utf8) else {
                throw JinjaError.runtime("\(family) prompt JSON is not UTF-8")
            }
            return value
        }
    }
}
