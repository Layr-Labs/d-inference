import Foundation
import ProviderCore

/// Keeps manual startup overrides until the durable selection changes. Only
/// model selection and Autopilot policy are live across scheduled windows;
/// all other inputs stay frozen.
struct ScheduledWindowSelection {
    private let startup: ProviderLoopConfig
    private var hasOpenedWindow = false
    private var hasSeenConfigFile: Bool
    private var usesSavedSelection = false
    /// Cached Autopilot builds verified by the previous window's provider
    /// (`ProviderLoop.autopilotCachedBuildHashes`): downloads, background
    /// verifications and prefetches made while it served.
    private var previousWindowCachedHashes: [String: String] = [:]

    init(startup: ProviderLoopConfig, configFileExists: Bool) {
        self.startup = startup
        self.hasSeenConfigFile = configFileExists
    }

    mutating func notePersistedSwitch() {
        usesSavedSelection = true
        hasSeenConfigFile = true
    }

    mutating func noteAutopilotCachedBuilds(_ hashes: [String: String]) {
        previousWindowCachedHashes = hashes
    }

    mutating func nextWindowConfiguration(
        resolveModels: ([String], Set<ProviderRuntimeCapability>) throws -> [ModelInfo] = {
            try ProviderModelSwitchValidation.scan($0, capabilities: $1)
        },
        resolveLocalPath: (String) -> URL? = { ModelScanner.resolveLocalPath(modelID: $0) },
        scanLocalModels: (HardwareInfo) -> [ModelInfo] = { ModelScanner.scanAllModels(hardwareInfo: $0) }
    ) throws -> ProviderLoopConfig {
        guard hasOpenedWindow else {
            hasOpenedWindow = true
            return startup
        }
        guard let path = startup.configPath else { return startup }
        if !hasSeenConfigFile, !FileManager.default.fileExists(atPath: path.path) {
            return startup
        }
        let savedBackend = try ConfigManager.load(from: path).backend
        let saved = savedBackend.enabledModels
        hasSeenConfigFile = true
        usesSavedSelection = usesSavedSelection || saved != startup.config.backend.enabledModels
        // A build verified only during a window is not in the startup
        // inventory: carrying it into the next window needs the rebuild below.
        let startupHashes = Self.cachedHashes(of: startup)
        let gainedCachedBuilds = previousWindowCachedHashes.contains { startupHashes[$0.key] != $0.value }
        guard usesSavedSelection || savedBackend.modelAutopilot != startup.config.backend.modelAutopilot
            || gainedCachedBuilds
        else { return startup }
        // Empty enabled_models means every eligible local model at normal start.
        // Re-resolve that set for each scheduled window as local artifacts change.
        let selectedIDs = !usesSavedSelection ? startup.models.map(\.id) : (saved.isEmpty
            ? try Switch.selectModels(requested: [], local: scanLocalModels(startup.hardware),
                capabilities: startup.runtimeCapabilities)
            : saved)
        let autopilot = savedBackend.modelAutopilot
        let inventoryIDs = autopilot.hasConsent ? autopilot.selectedModels : []
        let combinedIDs = selectedIDs + inventoryIDs.filter { !selectedIDs.contains($0) }
        // Cached builds stay in the Autopilot set while their bytes still hash
        // to a value verified at start or by the previous window's provider.
        // Each is scanned on its own: one that disappeared never fails the window.
        let cachedHashes = autopilot.hasConsent && !startup.config.coordinator.privateOnly
            ? startupHashes.mapValues { Set([$0]) }.merging(previousWindowCachedHashes.mapValues { Set([$0]) },
                uniquingKeysWith: { $0.union($1) })
            : [:]
        let isVerifiedCached: (ModelInfo) -> Bool = { model in
            model.weightHash.map { cachedHashes[model.id]?.contains($0) == true } ?? false
        }
        let cachedIDs = cachedHashes.keys.sorted().filter { !combinedIDs.contains($0) && resolveLocalPath($0) != nil }

        // Capture BEFORE scan's weight hashing, as in attachWeightHashes. A
        // concurrent file change must force re-hashing, never bless stale bytes.
        var fingerprints: [String: String] = [:]
        for id in combinedIDs + cachedIDs {
            if let snapshot = resolveLocalPath(id),
                let fingerprint = WeightHasher.snapshotFingerprint(snapshotDir: snapshot) {
                fingerprints[id] = fingerprint
            }
        }
        let verified = try resolveModels(combinedIDs, startup.runtimeCapabilities)
        let cached = cachedIDs.compactMap { id in
            (try? resolveModels([id], startup.runtimeCapabilities))?.first { $0.id == id && isVerifiedCached($0) }
        }
        let models = verified.filter { selectedIDs.contains($0.id) }
        let hashes = Dictionary(uniqueKeysWithValues: (verified + cached).compactMap { model in
            model.weightHash.map { (model.id, $0) }
        })
        var config = startup.config
        config.backend.enabledModels = saved
        config.backend.modelAutopilot = savedBackend.modelAutopilot
        return ProviderLoopConfig(
            coordinatorURL: startup.coordinatorURL,
            hardware: startup.hardware,
            models: models,
            config: config,
            authToken: startup.authToken,
            runtimeHashes: startup.runtimeHashes,
            runtimeCapabilities: startup.runtimeCapabilities,
            modelHashes: hashes,
            modelHashFingerprints: fingerprints,
            localEndpoint: startup.localEndpoint,
            configPath: path,
            autopilotInventory: verified.filter {
                $0.weightHash?.isEmpty == false && (inventoryIDs.contains($0.id) || isVerifiedCached($0))
            } + cached,
            autopilotPendingCandidates: autopilot.hasConsent ? startup.autopilotPendingCandidates : nil
        )
    }

    /// The cached builds a start path verified, outside its persisted
    /// selection, by build.
    private static func cachedHashes(of startup: ProviderLoopConfig) -> [String: String] {
        let persisted = Set(startup.config.backend.modelAutopilot.selectedModels)
        var hashes: [String: String] = [:]
        for model in startup.autopilotInventory where !persisted.contains(model.id) {
            if let hash = model.weightHash, !hash.isEmpty { hashes[model.id] = hash }
        }
        return hashes
    }
}
