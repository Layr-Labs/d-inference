import Foundation

enum ProductFormat {
    static func compactCount(_ value: UInt64) -> String {
        value.formatted(.number.notation(.compactName))
    }

    static func duration(_ interval: TimeInterval?) -> String {
        guard let interval else { return "—" }
        let hours = Int(interval) / 3_600
        let minutes = (Int(interval) % 3_600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func memory(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0 ... 1))) + " GB"
    }

    static func nextChange(_ date: Date?) -> String {
        guard let date else { return "No schedule limit" }
        return "Next change \(date.formatted(date: .omitted, time: .shortened))"
    }
}
