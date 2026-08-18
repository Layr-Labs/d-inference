import Foundation

/// An exact, non-negative US-dollar amount expressed in millionths of a dollar.
///
/// Coordinator money fields use integer micro-USD. Keeping that representation at
/// the UI boundary prevents binary floating-point rounding from changing balances.
struct MicroUSD: Codable, Comparable, Hashable, Sendable {
    enum ArithmeticError: Error, Equatable, Sendable {
        case overflow
        case insufficientFunds
    }

    static let zero = MicroUSD(0)

    let rawValue: Int64

    init(_ rawValue: Int64) {
        precondition(rawValue >= 0, "MicroUSD cannot represent a negative amount")
        self.rawValue = rawValue
    }

    init?(validating rawValue: Int64) {
        guard rawValue >= 0 else { return nil }
        self.rawValue = rawValue
    }

    static func < (lhs: MicroUSD, rhs: MicroUSD) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    func adding(_ other: MicroUSD) throws -> MicroUSD {
        let result = rawValue.addingReportingOverflow(other.rawValue)
        guard !result.overflow else { throw ArithmeticError.overflow }
        return MicroUSD(result.partialValue)
    }

    func subtracting(_ other: MicroUSD) throws -> MicroUSD {
        guard other <= self else { throw ArithmeticError.insufficientFunds }
        return MicroUSD(rawValue - other.rawValue)
    }

    /// Formats the exact decimal value without converting money through `Double`.
    func formattedUSD(locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 6
        formatter.roundingMode = .halfEven

        var decimal = Decimal(rawValue)
        decimal /= Decimal(1_000_000)
        return formatter.string(from: NSDecimalNumber(decimal: decimal)) ?? exactUSDFallback
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(Int64.self)
        guard let value = MicroUSD(validating: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Micro-USD values must be non-negative integers."
            )
        }
        self = value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private var exactUSDFallback: String {
        let dollars = rawValue / 1_000_000
        let micros = rawValue % 1_000_000
        guard micros > 0 else { return "$\(dollars).00" }

        var fraction = String(format: "%06lld", micros)
        while fraction.count > 2 && fraction.last == "0" {
            fraction.removeLast()
        }
        return "$\(dollars).\(fraction)"
    }
}
