import Foundation

struct OnboardingAccountLinkSession: Equatable, Sendable {
    static let lifetime: TimeInterval = 15 * 60
    static let pollInterval: TimeInterval = 5
    private static let fixtureCodes = ["7J4M-Q9TK", "C8PN-X3RW", "V6KF-2QHT"]

    let code: String
    let issuedAt: Date
    let expiresAt: Date

    static func fixture(issuedAt: Date, attempt: Int) -> Self {
        let code = fixtureCodes[attempt % fixtureCodes.count]
        return Self(code: code, issuedAt: issuedAt, expiresAt: issuedAt.addingTimeInterval(lifetime))
    }

    func isExpired(at date: Date) -> Bool {
        date >= expiresAt
    }

    func remainingMinutes(at date: Date) -> Int {
        max(0, Int(ceil(expiresAt.timeIntervalSince(date) / 60)))
    }
}
