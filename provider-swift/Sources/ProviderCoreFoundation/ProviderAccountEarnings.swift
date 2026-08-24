import Foundation

/// Authenticated provider-account earnings returned by
/// `GET /v1/provider/account-earnings` and echoed by `darkbloom earnings
/// --json`. The CLI adds the current machine identity fields so the app can
/// distinguish this Mac from the operator's other providers.
public struct ProviderAccountEarningsReport: Codable, Equatable, Sendable {
    public struct Earning: Codable, Equatable, Sendable {
        public var id: Int64
        public var accountID: String
        public var providerID: String
        public var providerKey: String
        public var jobID: String
        public var model: String
        public var amountMicroUSD: Int64
        public var promptTokens: Int
        public var completionTokens: Int
        public var createdAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case accountID = "account_id"
            case providerID = "provider_id"
            case providerKey = "provider_key"
            case jobID = "job_id"
            case model
            case amountMicroUSD = "amount_micro_usd"
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case createdAt = "created_at"
        }

        public init(
            id: Int64,
            accountID: String,
            providerID: String,
            providerKey: String,
            jobID: String,
            model: String,
            amountMicroUSD: Int64,
            promptTokens: Int,
            completionTokens: Int,
            createdAt: Date?
        ) {
            self.id = id
            self.accountID = accountID
            self.providerID = providerID
            self.providerKey = providerKey
            self.jobID = jobID
            self.model = model
            self.amountMicroUSD = amountMicroUSD
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.createdAt = createdAt
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(Int64.self, forKey: .id) ?? 0
            accountID = try container.decodeIfPresent(String.self, forKey: .accountID) ?? ""
            providerID = try container.decodeIfPresent(String.self, forKey: .providerID) ?? ""
            providerKey = try container.decodeIfPresent(String.self, forKey: .providerKey) ?? ""
            jobID = try container.decodeIfPresent(String.self, forKey: .jobID) ?? ""
            model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
            amountMicroUSD = try container.decodeIfPresent(Int64.self, forKey: .amountMicroUSD) ?? 0
            promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
            completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
            createdAt = try container.decodeIfPresent(
                ProviderEarningsTimestamp.self,
                forKey: .createdAt
            )?.date
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(accountID, forKey: .accountID)
            try container.encode(providerID, forKey: .providerID)
            try container.encode(providerKey, forKey: .providerKey)
            try container.encode(jobID, forKey: .jobID)
            try container.encode(model, forKey: .model)
            try container.encode(amountMicroUSD, forKey: .amountMicroUSD)
            try container.encode(promptTokens, forKey: .promptTokens)
            try container.encode(completionTokens, forKey: .completionTokens)
            try container.encodeIfPresent(
                createdAt.map(ProviderEarningsTimestamp.init),
                forKey: .createdAt
            )
        }
    }

    public struct ProviderIdentity: Codable, Equatable, Sendable {
        public var providerID: String
        public var providerKey: String
        public var machineID: String

        enum CodingKeys: String, CodingKey {
            case providerID = "provider_id"
            case providerKey = "provider_key"
            case machineID = "machine_id"
        }

        public init(providerID: String, providerKey: String, machineID: String) {
            self.providerID = providerID
            self.providerKey = providerKey
            self.machineID = machineID
        }
    }

    public var accountID: String
    public var currentProviderKey: String?
    public var currentMachineID: String?
    public var earnings: [Earning]
    public var providers: [ProviderIdentity]
    public var totalMicroUSD: Int64
    public var totalUSD: String
    public var count: Int64
    public var recentCount: Int
    public var historyLimit: Int
    public var availableBalanceMicroUSD: Int64
    public var availableBalanceUSD: String
    public var withdrawableBalanceMicroUSD: Int64
    public var withdrawableBalanceUSD: String

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case currentProviderKey = "current_provider_key"
        case currentMachineID = "current_machine_id"
        case earnings
        case providers
        case totalMicroUSD = "total_micro_usd"
        case totalUSD = "total_usd"
        case count
        case recentCount = "recent_count"
        case historyLimit = "history_limit"
        case availableBalanceMicroUSD = "available_balance_micro_usd"
        case availableBalanceUSD = "available_balance_usd"
        case withdrawableBalanceMicroUSD = "withdrawable_balance_micro_usd"
        case withdrawableBalanceUSD = "withdrawable_balance_usd"
    }

    public init(
        accountID: String,
        currentProviderKey: String? = nil,
        currentMachineID: String? = nil,
        earnings: [Earning],
        providers: [ProviderIdentity] = [],
        totalMicroUSD: Int64,
        totalUSD: String,
        count: Int64,
        recentCount: Int,
        historyLimit: Int,
        availableBalanceMicroUSD: Int64,
        availableBalanceUSD: String,
        withdrawableBalanceMicroUSD: Int64,
        withdrawableBalanceUSD: String
    ) {
        self.accountID = accountID
        self.currentProviderKey = currentProviderKey
        self.currentMachineID = currentMachineID
        self.earnings = earnings
        self.providers = providers
        self.totalMicroUSD = totalMicroUSD
        self.totalUSD = totalUSD
        self.count = count
        self.recentCount = recentCount
        self.historyLimit = historyLimit
        self.availableBalanceMicroUSD = availableBalanceMicroUSD
        self.availableBalanceUSD = availableBalanceUSD
        self.withdrawableBalanceMicroUSD = withdrawableBalanceMicroUSD
        self.withdrawableBalanceUSD = withdrawableBalanceUSD
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try container.decodeIfPresent(String.self, forKey: .accountID) ?? ""
        currentProviderKey = try container.decodeIfPresent(String.self, forKey: .currentProviderKey)
        currentMachineID = try container.decodeIfPresent(String.self, forKey: .currentMachineID)
        earnings = try container.decodeIfPresent([Earning].self, forKey: .earnings) ?? []
        providers = try container.decodeIfPresent([ProviderIdentity].self, forKey: .providers) ?? []
        totalMicroUSD = try container.decodeIfPresent(Int64.self, forKey: .totalMicroUSD) ?? 0
        totalUSD = try container.decodeIfPresent(String.self, forKey: .totalUSD) ?? "0"
        count = try container.decodeIfPresent(Int64.self, forKey: .count) ?? 0
        recentCount = try container.decodeIfPresent(Int.self, forKey: .recentCount) ?? earnings.count
        historyLimit = try container.decodeIfPresent(Int.self, forKey: .historyLimit) ?? earnings.count
        availableBalanceMicroUSD =
            try container.decodeIfPresent(Int64.self, forKey: .availableBalanceMicroUSD) ?? 0
        availableBalanceUSD =
            try container.decodeIfPresent(String.self, forKey: .availableBalanceUSD) ?? "0"
        withdrawableBalanceMicroUSD =
            try container.decodeIfPresent(Int64.self, forKey: .withdrawableBalanceMicroUSD) ?? 0
        withdrawableBalanceUSD =
            try container.decodeIfPresent(String.self, forKey: .withdrawableBalanceUSD) ?? "0"
    }
}

private struct ProviderEarningsTimestamp: Codable, Equatable, Sendable {
    let date: Date

    init(_ date: Date) {
        self.date = date
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            self.date = date
            return
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) {
            self.date = date
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected RFC3339 timestamp, got '\(raw)'"
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try container.encode(formatter.string(from: date))
    }
}
