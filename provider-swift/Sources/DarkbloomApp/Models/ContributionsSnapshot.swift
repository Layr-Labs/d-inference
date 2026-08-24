import Foundation

enum PayoutReadiness: String, Codable, Sendable {
    case ready
    case setupRequired = "setup-required"
}

/// A point-in-time account summary shaped only around coordinator-authoritative
/// account balance, lifetime summary, and bounded recent-ledger fields.
struct ContributionsSnapshot: Codable, Equatable, Sendable {
    var asOf: Date
    /// Every session key known to belong to the Mac running this app.
    var currentProviderKeys: Set<String>
    var availableBalance: MicroUSD
    var withdrawableBalance: MicroUSD
    var earnedLifetime: MicroUSD
    var lifetimeJobs: Int64
    var minimumPayout: MicroUSD
    var payoutReadiness: PayoutReadiness
    var records: [ContributionRecord]

    init(
        asOf: Date,
        currentProviderKeys: Set<String>,
        availableBalance: MicroUSD,
        withdrawableBalance: MicroUSD,
        earnedLifetime: MicroUSD,
        lifetimeJobs: Int64,
        minimumPayout: MicroUSD,
        payoutReadiness: PayoutReadiness,
        records: [ContributionRecord]
    ) {
        precondition(Self.isValid(
            asOf: asOf,
            currentProviderKeys: currentProviderKeys,
            availableBalance: availableBalance,
            withdrawableBalance: withdrawableBalance,
            earnedLifetime: earnedLifetime,
            lifetimeJobs: lifetimeJobs,
            minimumPayout: minimumPayout,
            records: records
        ), "Invalid contributions snapshot")

        self.asOf = asOf
        self.currentProviderKeys = currentProviderKeys
        self.availableBalance = availableBalance
        self.withdrawableBalance = withdrawableBalance
        self.earnedLifetime = earnedLifetime
        self.lifetimeJobs = lifetimeJobs
        self.minimumPayout = minimumPayout
        self.payoutReadiness = payoutReadiness
        self.records = records
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let asOf = try container.decode(Date.self, forKey: .asOf)
        let currentProviderKeys = try container.decode(Set<String>.self, forKey: .currentProviderKeys)
        let availableBalance = try container.decode(MicroUSD.self, forKey: .availableBalance)
        let withdrawableBalance = try container.decode(MicroUSD.self, forKey: .withdrawableBalance)
        let earnedLifetime = try container.decode(MicroUSD.self, forKey: .earnedLifetime)
        let lifetimeJobs = try container.decode(Int64.self, forKey: .lifetimeJobs)
        let minimumPayout = try container.decode(MicroUSD.self, forKey: .minimumPayout)
        let payoutReadiness = try container.decode(PayoutReadiness.self, forKey: .payoutReadiness)
        let records = try container.decode([ContributionRecord].self, forKey: .records)

        guard Self.isValid(
            asOf: asOf,
            currentProviderKeys: currentProviderKeys,
            availableBalance: availableBalance,
            withdrawableBalance: withdrawableBalance,
            earnedLifetime: earnedLifetime,
            lifetimeJobs: lifetimeJobs,
            minimumPayout: minimumPayout,
            records: records
        ) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Contributions snapshot invariants were not satisfied."
            ))
        }

        self.asOf = asOf
        self.currentProviderKeys = currentProviderKeys
        self.availableBalance = availableBalance
        self.withdrawableBalance = withdrawableBalance
        self.earnedLifetime = earnedLifetime
        self.lifetimeJobs = lifetimeJobs
        self.minimumPayout = minimumPayout
        self.payoutReadiness = payoutReadiness
        self.records = records
    }

    private static func isValid(
        asOf: Date,
        currentProviderKeys: Set<String>,
        availableBalance: MicroUSD,
        withdrawableBalance: MicroUSD,
        earnedLifetime: MicroUSD,
        lifetimeJobs: Int64,
        minimumPayout: MicroUSD,
        records: [ContributionRecord]
    ) -> Bool {
        guard currentProviderKeys.allSatisfy({ !$0.isEmpty }),
              withdrawableBalance <= availableBalance,
              lifetimeJobs >= 0,
              minimumPayout > .zero,
              Set(records.map(\.id)).count == records.count,
              records.allSatisfy({
                  !$0.id.isEmpty &&
                      !$0.providerKey.isEmpty &&
                      !$0.providerID.isEmpty &&
                      !$0.modelID.isEmpty &&
                      $0.timestamp <= asOf
              }) else {
            return false
        }
        return true
    }
}
