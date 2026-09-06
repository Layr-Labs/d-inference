import Foundation

/// Maps authenticated account earnings onto privacy-safe app records. The
/// coordinator includes provider-key/session-to-machine mappings so every
/// ephemeral key from this physical Mac remains in the "This Mac" scope.
enum ContributionsLiveMapping {
    static let liveMinimumPayout = MicroUSD(1_000_000)

    static func snapshot(from payload: ContributionsEarningsPayload, asOf: Date) -> ContributionsSnapshot {
        let providersByKey = Dictionary(
            payload.providers.filter { !$0.providerKey.isEmpty }.map { ($0.providerKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let providersByID = Dictionary(
            payload.providers.filter { !$0.providerID.isEmpty }.map { ($0.providerID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var currentProviderKeys = Set<String>()
        if let currentKey = payload.currentProviderKey, !currentKey.isEmpty {
            currentProviderKeys.insert(currentKey)
        }
        if let currentMachineID = payload.currentMachineID, !currentMachineID.isEmpty {
            currentProviderKeys.formUnion(payload.providers.lazy
                .filter { $0.machineID == currentMachineID }
                .map(\.providerKey)
                .filter { !$0.isEmpty })
        }
        let records = payload.earnings.enumerated().map { index, earning in
            record(
                from: earning,
                fallbackIndex: index,
                providersByKey: providersByKey,
                providersByID: providersByID,
                currentMachineID: payload.currentMachineID,
                asOf: asOf
            )
        }
        return ContributionsSnapshot(
            asOf: asOf,
            currentProviderKeys: currentProviderKeys,
            availableBalance: nonNegative(payload.availableBalanceMicroUSD),
            withdrawableBalance: min(
                nonNegative(payload.withdrawableBalanceMicroUSD),
                nonNegative(payload.availableBalanceMicroUSD)
            ),
            earnedLifetime: nonNegative(payload.totalMicroUSD),
            lifetimeJobs: max(0, payload.count),
            minimumPayout: liveMinimumPayout,
            payoutReadiness: .ready,
            records: records
        )
    }

    private static func record(
        from earning: ContributionsEarningsPayload.Earning,
        fallbackIndex: Int,
        providersByKey: [String: ContributionsEarningsPayload.ProviderIdentity],
        providersByID: [String: ContributionsEarningsPayload.ProviderIdentity],
        currentMachineID: String?,
        asOf: Date
    ) -> ContributionRecord {
        let id: String
        if earning.id != 0 {
            id = "earning-\(earning.id)"
        } else if !earning.jobID.isEmpty {
            id = "job-\(earning.jobID)"
        } else {
            id = "earning-fallback-\(fallbackIndex)"
        }
        let providerKey = earning.providerKey.isEmpty
            ? (earning.providerID.isEmpty ? "unknown-provider" : earning.providerID)
            : earning.providerKey
        let providerID = earning.providerID.isEmpty ? providerKey : earning.providerID
        let identity = providersByKey[earning.providerKey] ?? providersByID[earning.providerID]
        let modelID = earning.model.isEmpty ? "unknown" : earning.model
        return ContributionRecord(
            id: id,
            timestamp: min(earning.createdAt ?? asOf, asOf),
            providerKey: providerKey,
            providerID: providerID,
            providerName: providerName(
                identity: identity,
                currentMachineID: currentMachineID
            ),
            modelID: modelID,
            modelName: modelID == "base_reward" ? "Base reward" : modelID,
            inputTokens: nonNegativeTokens(earning.promptTokens),
            outputTokens: nonNegativeTokens(earning.completionTokens),
            amount: nonNegative(earning.amountMicroUSD)
        )
    }

    private static func providerName(
        identity: ContributionsEarningsPayload.ProviderIdentity?,
        currentMachineID: String?
    ) -> String {
        guard let machineID = identity?.machineID, !machineID.isEmpty else {
            return "Provider"
        }
        if machineID == currentMachineID {
            return "This Mac"
        }
        return "Mac ••••\(machineID.suffix(4).uppercased())"
    }

    private static func nonNegative(_ value: Int64) -> MicroUSD {
        MicroUSD(validating: value) ?? .zero
    }

    private static func nonNegativeTokens(_ value: Int) -> UInt64 {
        value > 0 ? UInt64(value) : 0
    }
}
