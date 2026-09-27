import Foundation
import Jinja

/// One UTC Gregorian day owned by a request, shared by every render and retry.
public struct PromptRenderDate: Sendable, Equatable {
    public static let bodyField = "_darkbloom_prompt_date"
    static let clockContextKey = "_darkbloom_request_clock"
    public let value: String

    public init?(_ value: String) {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ index, byte in
                  index == 4 || index == 7 || (48...57).contains(byte)
              }) else { return nil }
        let year = Int(value.prefix(4))!
        let month = Int(String(value.dropFirst(5).prefix(2)))!
        let day = Int(value.suffix(2))!
        guard year > 0, (1...12).contains(month) else { return nil }
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[month - 1]).contains(day) else { return nil }
        self.value = value
    }

    public static func capture(at date: Date = Date()) -> Self {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return Self(String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!))!
    }

    /// Only direct, literal date calls have reviewed cross-renderer semantics.
    /// Removing recognized calls and checking the remainder also rejects aliases
    /// and computed formats in branches a render fixture may never exercise.
    public static func supportsTemplate(_ source: String) -> Bool {
        let remainder = source.replacingOccurrences(
            of: #"(?<![\p{L}\p{N}_.])strftime_now\s*\(\s*(?:"%Y-%m-%d"|'%Y-%m-%d')\s*\)"#,
            with: "", options: .regularExpression)
        return !remainder.contains("strftime_now")
    }

    public func templateContext() -> [String: any Sendable] {
        [Self.clockContextKey: function]
    }

    private var function: Value {
        .function { args, kwargs, environment in
            if args.count == 1, kwargs.isEmpty,
               case .string("%Y-%m-%d") = args[0] {
                return .string(value)
            }
            // Unsupported sources remain ineligible for cache contracts; ordinary
            // serving retains the library's behavior for their other formats.
            return try Globals.strftimeNow(args, kwargs, environment)
        }
    }
}
