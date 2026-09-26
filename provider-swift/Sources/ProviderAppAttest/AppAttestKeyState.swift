import Foundation

/// Persisted limits on new Apple keys: at most `limit` generations per
/// coordinator/environment per `window`, shared across account scopes.
enum KeyGenerationBudget {
    static let window: TimeInterval = 3600
    static let limit = 5

    static func scope(_ base: String, environment: String) -> String {
        base + ":" + environment + ":generation-budget"
    }
}

/// Local, read-only summary of the stored key for `darkbloom doctor`. It holds
/// no key identifier, proof or account data.
public struct AppAttestKeyState: Codable, Sendable, Equatable {
    /// A usable Apple key identifier is stored for this account scope.
    public var recordPresent: Bool
    /// The stored key completed Apple enrollment on this Mac.
    public var attested: Bool
    /// Without a usable key: Unix seconds when a replacement may be generated,
    /// while the per-key cooldown or the shared hourly budget blocks it.
    public var generationBlockedUntil: Double?

    public init(recordPresent: Bool, attested: Bool, generationBlockedUntil: Double?) {
        self.recordPresent = recordPresent
        self.attested = attested
        self.generationBlockedUntil = generationBlockedUntil
    }

    init(record: ShadowKeyRecord?, budget: ShadowKeyRecord?, now: Date) {
        if let record, !record.keyID.isEmpty {
            self.init(recordPresent: true, attested: record.attested, generationBlockedUntil: nil)
            return
        }
        var blockedUntil = record?.generationAllowedAt
        if let budget, now.timeIntervalSince(budget.createdAt) < KeyGenerationBudget.window,
           (budget.generationCount ?? 0) >= KeyGenerationBudget.limit {
            let budgetResets = budget.createdAt.addingTimeInterval(KeyGenerationBudget.window)
            blockedUntil = max(blockedUntil ?? budgetResets, budgetResets)
        }
        self.init(recordPresent: false, attested: false,
                  generationBlockedUntil: blockedUntil.flatMap { $0 > now ? $0.timeIntervalSince1970 : nil })
    }
}
