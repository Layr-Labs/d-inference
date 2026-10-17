import CoreFoundation
import Foundation

func qwenPartitionInteger(_ text: [String: Any], _ key: String, allowZero: Bool = false) throws -> Int {
    guard let value = text[key] as? Int, value >= (allowZero ? 0 : 1), value <= 1_048_576,
        let number = text[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
        throw ProbeError("Qwen partition requires an explicit \(allowZero ? "nonnegative" : "positive") integer \(key)")
    }
    return value
}
