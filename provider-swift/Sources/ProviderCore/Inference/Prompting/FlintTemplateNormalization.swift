import Foundation
import Jinja

/// Flint's template serializes each argument independently. Null is a value:
/// dropping it would remove object keys and shift array positions on replay.
/// Uses the existing MiMo bridge pattern without changing generic sanitization.
enum FlintTemplateNormalization {
    static func object(_ value: [String: any Sendable]) -> [String: any Sendable] {
        value.mapValues(preserveNull)
    }

    private static func preserveNull(_ value: any Sendable) -> any Sendable {
        let typeName = String(reflecting: type(of: value))
        if value is NSNull || (typeName.hasPrefix("MLXLMServer.")
            && typeName.split(separator: ".").last == "JSONNull") {
            return Jinja.Value.null
        }
        if let dictionary = value as? [String: any Sendable] { return object(dictionary) }
        if let array = value as? [any Sendable] { return array.map(preserveNull) }
        return value
    }
}
