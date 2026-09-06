import Foundation

// MARK: - Wire mirrors (decodable twins of ProviderCore's JSON output)

/// Mirror of `ProviderCore.CatalogModel` as emitted by
/// `darkbloom models catalog --json` (snake_case keys).
struct CLICatalogModel: Decodable, Equatable, Sendable {
    let id: String
    let s3Name: String
    let displayName: String
    let modelType: String
    let sizeGb: Double
    let description: String?
    let minRamGb: Int?
    let family: String?
    let quantization: String?
    let maxContextLength: Int?
    let capabilities: [String]?
    let totalSizeBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case s3Name = "s3_name"
        case displayName = "display_name"
        case modelType = "model_type"
        case sizeGb = "size_gb"
        case description
        case minRamGb = "min_ram_gb"
        case family
        case quantization
        case maxContextLength = "max_context_length"
        case capabilities
        case totalSizeBytes = "total_size_bytes"
    }
}

/// Mirror of `ProviderCore.ModelInfo` as emitted inside
/// `darkbloom models list --json` (snake_case keys).
struct CLILocalModelEntry: Decodable, Equatable, Sendable {
    let id: String
    let modelType: String?
    let quantization: String?
    let sizeBytes: UInt64
    let estimatedMemoryGb: Double

    enum CodingKeys: String, CodingKey {
        case id
        case modelType = "model_type"
        case quantization
        case sizeBytes = "size_bytes"
        case estimatedMemoryGb = "estimated_memory_gb"
    }
}

/// Mirror of the CLI's `ModelsOutput` wrapper (camelCase keys: the CLI
/// declares no custom CodingKeys there).
struct CLIModelListOutput: Decodable, Equatable, Sendable {
    let cacheDirectory: String?
    let filteredByConfig: Bool
    let models: [CLILocalModelEntry]
}

/// Mirror of `ProviderCore.ModelDownloadStoragePlan` from
/// `models catalog --json --include-download-plans`.
struct CLIModelDownloadStoragePlan: Decodable, Equatable, Sendable {
    let remainingBytes: Int64
    let reserveBytes: Int64
    let requiredAvailableBytes: Int64
    let availableBytes: Int64?
    let hasSufficientCapacity: Bool

    enum CodingKeys: String, CodingKey {
        case remainingBytes = "remaining_bytes"
        case reserveBytes = "reserve_bytes"
        case requiredAvailableBytes = "required_available_bytes"
        case availableBytes = "available_bytes"
        case hasSufficientCapacity = "has_sufficient_capacity"
    }
}

struct CLIModelDownloadPlanOutput: Decodable {
    let modelID: String
    let downloadPlan: CLIModelDownloadStoragePlan?

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case downloadPlan = "download_plan"
    }
}

/// A CLI-computed verdict. Unknown/missing results never assert compatibility;
/// the app does not know or duplicate the provider's runtime requirements policy.
struct CLIModelRuntimeEligibility: Decodable, Equatable, Sendable {
    enum Status: String, Sendable {
        case eligible
        case ineligible
        case unknown
    }

    let status: Status
    let reason: String

    static let unreported = Self(
        status: .unknown,
        reason: "The installed provider did not report runtime compatibility. Update the provider, then refresh the catalog.")

    init(status: Status, reason: String) {
        self.status = status
        self.reason = reason
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawStatus = try container.decodeIfPresent(String.self, forKey: .status)
        status = rawStatus.flatMap(Status.init(rawValue:)) ?? .unknown
        let detail = try container.decodeIfPresent(String.self, forKey: .reason)
        reason = detail.flatMap { $0.isEmpty ? nil : $0 } ?? Self.unreported.reason
    }

    private enum CodingKeys: String, CodingKey { case status, reason }
}

struct CLICatalogPlanOutput: Decodable {
    let models: [CLICatalogModel]
    let downloadPlans: [String: CLIModelDownloadStoragePlan]
    let runtimeEligibility: [String: CLIModelRuntimeEligibility]?

    enum CodingKeys: String, CodingKey {
        case models
        case downloadPlans = "download_plans"
        case runtimeEligibility = "runtime_eligibility"
    }
}

/// Everything the library surface needs, sourced from one refresh pass:
/// coordinator catalog + local scan + daemon warmth + this Mac's memory.
struct ModelLibrarySnapshot: Equatable, Sendable {
    let catalog: [CLICatalogModel]
    /// A failed catalog still carries a fresh local inventory. Nil means the
    /// catalog succeeded; an empty catalog alone does not imply an outage.
    let catalogError: ModelCatalogCLIError?
    let local: [CLILocalModelEntry]
    let downloadPlans: [String: CLIModelDownloadStoragePlan]
    let runtimeEligibility: [String: CLIModelRuntimeEligibility]
    let warmModelIDs: Set<String>
    let servingModelID: String?
    let physicalMemoryGB: Int?
    let fetchedAt: Date

    init(
        catalog: [CLICatalogModel],
        catalogError: ModelCatalogCLIError? = nil,
        local: [CLILocalModelEntry],
        downloadPlans: [String: CLIModelDownloadStoragePlan] = [:],
        runtimeEligibility: [String: CLIModelRuntimeEligibility] = [:],
        warmModelIDs: Set<String>,
        servingModelID: String?,
        physicalMemoryGB: Int?,
        fetchedAt: Date
    ) {
        self.catalog = catalog
        self.catalogError = catalogError
        self.local = local
        self.downloadPlans = downloadPlans
        self.runtimeEligibility = runtimeEligibility
        self.warmModelIDs = warmModelIDs
        self.servingModelID = servingModelID
        self.physicalMemoryGB = physicalMemoryGB
        self.fetchedAt = fetchedAt
    }

    func runtimeEligibility(for modelID: String) -> CLIModelRuntimeEligibility {
        runtimeEligibility[modelID] ?? .unreported
    }

}
