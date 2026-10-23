import Foundation

/// The start path's Autopilot inventory under saved consent: the persisted
/// selection as before, plus each cached build that is a verified current
/// catalog build this machine can run. When the catalog cannot be fetched, a
/// build recorded in `AutopilotDownloadLedger` stays while its bytes still
/// hash to the recorded value. Verification reuses the start path's single
/// weight-hash pass rather than reading every build twice.
public struct AutopilotStartInventory: Sendable {
    public let settings: ModelAutopilotSettings
    /// The catalog by build ID; nil when it could not be fetched.
    public let catalog: [String: CatalogModel]?
    public let recordedDownloads: [String: String]
    public let memoryGb: Double
    public let runtimeCapabilities: Set<ProviderRuntimeCapability>

    public init(settings: ModelAutopilotSettings, catalog: [CatalogModel]?, recordedDownloads: [String: String],
                memoryGb: Double, runtimeCapabilities: Set<ProviderRuntimeCapability>) {
        self.settings = settings
        self.catalog = catalog.map { Dictionary($0.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        self.recordedDownloads = recordedDownloads
        self.memoryGb = memoryGb
        self.runtimeCapabilities = runtimeCapabilities
    }

    /// Fetches the text catalog the opt-in picker reads (bounded by the
    /// catalog client's timeout) and the download ledger beside the config.
    /// Either may be missing.
    public static func load(settings: ModelAutopilotSettings, coordinatorURL: String, configDirectory: URL,
                            memoryGb: Double, runtimeCapabilities: Set<ProviderRuntimeCapability>) async -> Self {
        let catalog = try? await ModelCatalogClient(coordinatorURL: coordinatorURL).fetchCatalog(typeFilter: "text")
        let ledger = AutopilotDownloadLedger.read(from: AutopilotDownloadLedger.url(configDirectory: configDirectory))
        return Self(settings: settings, catalog: catalog, recordedDownloads: ledger.weightHashes,
                    memoryGb: memoryGb, runtimeCapabilities: runtimeCapabilities)
    }

    /// Whether a local build is worth hashing for the set.
    public func isCandidate(_ model: ModelInfo) -> Bool {
        guard settings.hasConsent,
              ModelRuntimeRequirements.isEligible(modelID: model.id, available: runtimeCapabilities) else { return false }
        if settings.allows(model.id) { return true }
        guard AutopilotModelSet.isReportableID(model.id) else { return false }
        if let catalog {
            return catalog[model.id].map {
                AutopilotBuildEligibility.allowsCachedBuild(model, entry: $0, memoryGb: memoryGb,
                    runtimeCapabilities: runtimeCapabilities)
            } ?? false
        }
        return recordedDownloads[model.id] != nil && EngineV2SupportedModels.isSupported(model: model)
            && AutopilotBuildEligibility.fitsLoadBudget(sizeGb: model.estimatedMemoryGb, memoryGb: memoryGb)
    }

    /// The hashed candidates that belong to the set, capped like the report.
    public func inventory(from hashed: [ModelInfo]) -> [ModelInfo] {
        let verified = hashed.filter { model in
            guard isCandidate(model), let hash = model.weightHash, !hash.isEmpty else { return false }
            if settings.allows(model.id) { return true }
            if let catalog {
                return catalog[model.id].map {
                    AutopilotBuildEligibility.isCurrentCatalogBuild(weightHash: hash, entry: $0)
                } ?? false
            }
            return recordedDownloads[model.id] == hash
        }
        let members = Set(AutopilotModelSet.effective(selected: settings.selectedModels,
            cached: verified.map(\.id).filter { !settings.allows($0) }))
        var seen = Set<String>()
        return verified.filter { members.contains($0.id) && seen.insert($0.id).inserted }
    }
}
