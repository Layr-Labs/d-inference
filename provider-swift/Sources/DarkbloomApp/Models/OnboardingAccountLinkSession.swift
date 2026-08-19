import Foundation

struct OnboardingAccountLinkSession: Equatable, Sendable {
    /// Fixture defaults: how long a sample code lives and how often the UI
    /// claims approval is polled. Live sessions derive their expiry from the
    /// coordinator's `expires_in` instead — the statics describe the preview.
    static let lifetime: TimeInterval = 15 * 60
    static let pollInterval: TimeInterval = 5
    private static let fixtureCodes = ["7J4M-Q9TK", "C8PN-X3RW", "V6KF-2QHT"]

    let code: String
    let issuedAt: Date
    let expiresAt: Date
    /// Only set on live sessions: the coordinator-provided approval URL, kept
    /// so the UI can show it for manual opening (the flow model also deeplinks
    /// it automatically when the `.code` event arrives). Fixtures leave it nil.
    var verificationURI: String? = nil

    static func fixture(issuedAt: Date, attempt: Int) -> Self {
        let code = fixtureCodes[attempt % fixtureCodes.count]
        return Self(code: code, issuedAt: issuedAt, expiresAt: issuedAt.addingTimeInterval(lifetime))
    }

    /// A session backed by a real `darkbloom login --json` `.code` event:
    /// coordinator-issued code and expiry, not the preview fixture.
    static func live(code: String, verificationURI: String, issuedAt: Date, expiresIn: Int) -> Self {
        Self(
            code: code,
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(TimeInterval(max(expiresIn, 0))),
            verificationURI: verificationURI
        )
    }

    /// How long this session's code stays valid, for countdown copy. Fixture
    /// sessions answer 15 minutes; live sessions answer the coordinator's
    /// `expires_in`.
    var lifetimeMinutes: Int {
        max(0, Int(ceil(expiresAt.timeIntervalSince(issuedAt) / 60)))
    }

    func isExpired(at date: Date) -> Bool {
        date >= expiresAt
    }

    func remainingMinutes(at date: Date) -> Int {
        max(0, Int(ceil(expiresAt.timeIntervalSince(date) / 60)))
    }
}
