import Foundation
import ProviderCoreFoundation

struct OnboardingModelChoice: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let summary: String
    let sizeBytes: Int64
    let minimumMemoryGB: Int
    let isInstalled: Bool
}

struct OnboardingPreparationPlan: Equatable, Sendable {
    let choices: [OnboardingModelChoice]
    let recommendedModelID: String
    let fetchedAt: Date
}

enum OnboardingPreparationServiceError: Error, Equatable, LocalizedError, Sendable {
    case noCompatibleModel
    case modelUnavailable(String)
    case providerEvidenceTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .noCompatibleModel:
            "The catalog has no model that is confirmed to fit this Mac's memory and available storage."
        case .modelUnavailable(let id):
            "The selected model (\(id)) is no longer available in the compatible catalog. Refresh the catalog and choose again."
        case .providerEvidenceTimedOut(let id):
            "Darkbloom started, but this Mac did not confirm a live provider and local endpoint serving \(id) in time. Try starting it again."
        }
    }
}

protocol OnboardingPreparationServicing: Sendable {
    func fetchPlan() async throws -> OnboardingPreparationPlan
    func downloadEvents(modelID: String) -> AsyncThrowingStream<ModelDownloadStreamEvent, Error>
    func startProvider(modelID: String) async throws
}

struct OnboardingPreparationService: OnboardingPreparationServicing {
    private static let downloadHeadroomBytes: Int64 = 2 * 1_073_741_824

    let catalog: any ModelCatalogCLIRunning
    let startCLI: any SetupStartCLIRunning
    let availableStorageBytes: @Sendable () -> UInt64?

    init(
        catalog: any ModelCatalogCLIRunning = ProcessModelCatalogCLIRunner(),
        startCLI: any SetupStartCLIRunning = ProcessSetupStartCLI(),
        availableStorageBytes: @escaping @Sendable () -> UInt64? = Self.liveAvailableStorageBytes
    ) {
        self.catalog = catalog
        self.startCLI = startCLI
        self.availableStorageBytes = availableStorageBytes
    }

    func fetchPlan() async throws -> OnboardingPreparationPlan {
        let snapshot = try await catalog.fetchSnapshot()
        guard let memoryGB = snapshot.physicalMemoryGB else {
            throw OnboardingPreparationServiceError.noCompatibleModel
        }
        let localIDs = Set(snapshot.local.map(\.id))
        let freeStorage = availableStorageBytes().map(Int64.init(clamping:))

        let choices = snapshot.catalog.compactMap { model -> OnboardingModelChoice? in
            guard let minimumMemoryGB = model.minRamGb,
                  minimumMemoryGB <= memoryGB,
                  isInferenceModel(model)
            else { return nil }

            let sizeBytes = max(
                0,
                model.totalSizeBytes ?? Int64((model.sizeGb * 1_000_000_000).rounded())
            )
            let installed = localIDs.contains(model.id)
            if !installed, !storageAllowsDownload(
                fullSizeBytes: sizeBytes,
                plan: snapshot.downloadPlans[model.id],
                fallbackAvailableBytes: freeStorage
            ) {
                return nil
            }
            return OnboardingModelChoice(
                id: model.id,
                displayName: model.displayName,
                summary: model.description ?? "Private local inference model",
                sizeBytes: sizeBytes,
                minimumMemoryGB: minimumMemoryGB,
                isInstalled: installed
            )
        }

        guard !choices.isEmpty else {
            throw OnboardingPreparationServiceError.noCompatibleModel
        }

        // Prefer an already-present compatible model. Otherwise choose the
        // strongest catalog fit by minimum-RAM requirement, with smaller bytes
        // as the deterministic tie-breaker. No registry id is hardcoded.
        let catalogByID = Dictionary(
            snapshot.catalog.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let ordered = choices.sorted { lhs, rhs in
            if lhs.isInstalled != rhs.isInstalled { return lhs.isInstalled }
            let leftKind = recommendationKindRank(catalogByID[lhs.id]?.modelType)
            let rightKind = recommendationKindRank(catalogByID[rhs.id]?.modelType)
            if leftKind != rightKind { return leftKind < rightKind }
            if lhs.minimumMemoryGB != rhs.minimumMemoryGB {
                return lhs.minimumMemoryGB > rhs.minimumMemoryGB
            }
            if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes < rhs.sizeBytes }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
        return OnboardingPreparationPlan(
            choices: choices.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            },
            recommendedModelID: ordered[0].id,
            fetchedAt: snapshot.fetchedAt
        )
    }

    /// Live app plans come from the bundled CLI, which asks the downloader
    /// to validate staged files, credit `.part` prefixes, and sample the actual
    /// cache volume without mutating it. The fallback keeps injected/older test
    /// adapters usable, but live planning never charges a resumed download the
    /// full catalog size.
    private func storageAllowsDownload(
        fullSizeBytes: Int64,
        plan: CLIModelDownloadStoragePlan?,
        fallbackAvailableBytes: Int64?
    ) -> Bool {
        if let plan {
            let reserve = max(Self.downloadHeadroomBytes, max(0, plan.reserveBytes))
            let remaining = max(0, plan.remainingBytes)
            let required = remaining > Int64.max - reserve
                ? Int64.max
                : remaining + reserve
            if let available = plan.availableBytes {
                return available >= required
            }
            return plan.hasSufficientCapacity
        }

        guard let fallbackAvailableBytes else { return true }
        let size = max(0, fullSizeBytes)
        let required = size > Int64.max - Self.downloadHeadroomBytes
            ? Int64.max
            : size + Self.downloadHeadroomBytes
        return fallbackAvailableBytes >= required
    }

    func downloadEvents(modelID: String) -> AsyncThrowingStream<ModelDownloadStreamEvent, Error> {
        catalog.downloadEvents(modelID: modelID)
    }

    func startProvider(modelID: String) async throws {
        try await startCLI.start(modelID: modelID)
    }

    private func isInferenceModel(_ model: CLICatalogModel) -> Bool {
        let type = model.modelType.lowercased()
        if type == "embeddings" || type == "embedding" { return false }
        if type == "text" || type == "vision" || type == "vlm" || type == "multimodal" {
            return true
        }
        return model.capabilities?.contains("text-generation") == true
    }

    private func recommendationKindRank(_ modelType: String?) -> Int {
        switch modelType?.lowercased() {
        case "text": 0
        case "vision", "vlm", "multimodal": 1
        default: 2
        }
    }

    private static func liveAvailableStorageBytes() -> UInt64? {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/")
        return (attributes?[.systemFreeSize] as? NSNumber)?.uint64Value
    }
}

struct OnboardingProviderEvidence: Equatable, Sendable {
    let daemonState: DaemonState?
    let localEndpoint: LocalEndpointInfo?
    let processIsAlive: Bool
    let localEndpointProcessIsAlive: Bool
    let sampledAt: Date

    init(
        daemonState: DaemonState?,
        localEndpoint: LocalEndpointInfo?,
        processIsAlive: Bool? = nil,
        localEndpointProcessIsAlive: Bool? = nil,
        sampledAt: Date = .now
    ) {
        self.daemonState = daemonState
        self.localEndpoint = localEndpoint
        self.processIsAlive = processIsAlive
            ?? daemonState.map { DaemonStateRuntimeTruth.belongsToLiveProcess($0) }
            ?? false
        self.localEndpointProcessIsAlive = localEndpointProcessIsAlive
            ?? localEndpoint.map { LocalEndpointRuntimeTruth.belongsToLiveProcess($0) }
            ?? false
        self.sampledAt = sampledAt
    }

    static var live: Self {
        Self(
            daemonState: DaemonStateFile.read(),
            localEndpoint: LocalEndpointDiscovery.readInfo()
        )
    }

    func reportsStarted(modelID: String) -> Bool {
        guard let daemonState,
              let localEndpoint,
              processIsAlive,
              localEndpointProcessIsAlive,
              !daemonState.isStale(now: sampledAt.timeIntervalSince1970),
              let daemonIdentity = daemonState.processIdentity,
              localEndpoint.processIdentity == daemonIdentity
        else { return false }
        let modelIsLoaded = daemonState.currentModel == modelID
            || daemonState.warmModels.contains(modelID)
        guard modelIsLoaded,
              localEndpoint.pid == daemonState.pid,
              localEndpoint.port > 0,
              let baseURL = URL(string: localEndpoint.baseURL),
              baseURL.host != nil,
              baseURL.scheme == "http" || baseURL.scheme == "https"
        else { return false }
        return true
    }

}
