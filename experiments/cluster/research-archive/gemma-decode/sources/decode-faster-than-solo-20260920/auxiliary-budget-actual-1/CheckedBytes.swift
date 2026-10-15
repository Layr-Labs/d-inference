import Foundation

enum QwenLongPrefillBudgetError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let value): return value } }
}

enum QwenLongPrefillCheckedBytes {
    static func product(_ values: [Int]) throws -> Int {
        var result = 1
        for value in values {
            guard value >= 0 else { throw QwenLongPrefillBudgetError.invalid("Negative byte-count factor") }
            let next = result.multipliedReportingOverflow(by: value)
            guard !next.overflow else { throw QwenLongPrefillBudgetError.invalid("Byte-count product overflow") }
            result = next.partialValue
        }
        return result
    }

    static func sum(_ values: [Int]) throws -> Int {
        var result = 0
        for value in values {
            guard value >= 0 else { throw QwenLongPrefillBudgetError.invalid("Negative byte-count term") }
            let next = result.addingReportingOverflow(value)
            guard !next.overflow else { throw QwenLongPrefillBudgetError.invalid("Byte-count sum overflow") }
            result = next.partialValue
        }
        return result
    }
}

