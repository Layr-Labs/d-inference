import Foundation

enum ContributionsPresentation {
    static func amount(_ value: MicroUSD) -> String {
        value.formattedUSD()
    }

    static func jobCount(_ value: Int64) -> String {
        value.formatted()
    }

    static func tokenCount(_ value: UInt64) -> String {
        ProductFormat.compactCount(value)
    }

    static func ledgerDate(_ date: Date, relativeTo now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func updateText(_ date: Date, relativeTo now: Date = .now) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 { return "Updated just now" }
        if elapsed < 3_600 { return "Updated \(Int(elapsed / 60))m ago" }
        return "Updated \(date.formatted(date: .omitted, time: .shortened))"
    }

    static func editableDollars(_ value: MicroUSD, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 6
        formatter.usesGroupingSeparator = false

        var decimal = Decimal(value.rawValue)
        decimal /= Decimal(1_000_000)
        return formatter.string(from: NSDecimalNumber(decimal: decimal)) ?? "0.00"
    }

    static func microUSD(fromDollars text: String, locale: Locale = .current) -> MicroUSD? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let decimalSeparator = locale.decimalSeparator ?? "."
        let escapedSeparator = NSRegularExpression.escapedPattern(for: decimalSeparator)
        let pattern = "^[0-9]+(?:\(escapedSeparator)[0-9]{0,6})?$"
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }

        let normalized = decimalSeparator == "."
            ? value
            : value.replacingOccurrences(of: decimalSeparator, with: ".")
        guard var dollars = Decimal(
            string: normalized,
            locale: Locale(identifier: "en_US_POSIX")
        ), dollars >= 0 else { return nil }

        dollars *= Decimal(1_000_000)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &dollars, 0, .plain)
        guard rounded == dollars else { return nil }

        let number = NSDecimalNumber(decimal: rounded)
        guard number != .notANumber,
              number.compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending else {
            return nil
        }
        return MicroUSD(validating: number.int64Value)
    }

    static func payoutError(_ error: PayoutValidationError) -> String {
        switch error {
        case .unavailable:
            "Contributions are unavailable right now. Try again when account data returns."
        case .setupRequired:
            "Payouts aren’t ready. Review the authoritative payout status before requesting a withdrawal."
        case .nonPositive:
            "Enter an amount greater than zero."
        case .belowMinimum(let minimum):
            "The minimum withdrawal is \(amount(minimum))."
        case .exceedsWithdrawable(let withdrawable):
            "You can withdraw up to \(amount(withdrawable))."
        case .alreadySubmitting:
            "A preview withdrawal is already in progress."
        }
    }
}

extension ContributionScope {
    var title: String {
        switch self {
        case .thisMac: "This Mac"
        case .allMacs: "All Macs"
        }
    }
}
