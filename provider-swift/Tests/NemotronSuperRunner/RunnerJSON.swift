import Foundation

/// Sendable JSON value for runner events, the ready file and diagnostics.
/// Fields carry sizes, timings and opaque reservation IDs, never prompt or media content.
enum RunnerJSON: Encodable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral
{
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([RunnerJSON])
    case object([String: RunnerJSON])

    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(Int64(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(dictionaryLiteral elements: (String, RunnerJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    init(arrayLiteral elements: RunnerJSON...) { self = .array(elements) }

    static func bytes(_ value: UInt64) -> RunnerJSON { .int(Int64(clamping: value)) }
    static func bytes(_ value: Int) -> RunnerJSON { .int(Int64(value)) }
    static func count(_ value: Int) -> RunnerJSON { .int(Int64(value)) }
    static func seconds(_ value: Duration) -> RunnerJSON {
        let (whole, attoseconds) = value.components
        return .double(Double(whole) + Double(attoseconds) / 1e18)
    }
    static func optional(_ value: UInt64?) -> RunnerJSON { value.map(bytes) ?? .null }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value.isFinite ? value : 0)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    func merging(_ other: [String: RunnerJSON]) -> RunnerJSON {
        guard case .object(var fields) = self else { return .object(other) }
        fields.merge(other) { _, new in new }
        return .object(fields)
    }

    func encoded(pretty: Bool = false) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        // Encoding a closed value enum cannot fail; keep the log writer total.
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }
}
