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

    init(startup: ProviderLoopConfig, configFileExists: Bool) {
        self.startup = startup
        self.hasSeenConfigFile = configFileExists
    }

    mutating func notePersistedSwitch() {
        usesSavedSelection = true
        hasSeenConfigFile = true
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
        guard usesSavedSelection || savedBackend.modelAutopilot != startup.config.backend.modelAutopilot
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
        // to the value verified at start or recorded for an Autopilot download.
        // Each is scanned on its own: one that disappeared never fails the window.
        let cachedHashes = autopilot.hasConsent && !startup.config.coordinator.privateOnly
            ? verifiedCachedHashes() : [:]
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
            } + cached
        )
    }

    /// Hashes the start path verified for cached Autopilot builds, plus the
    /// recorded Autopilot downloads, by build.
    private func verifiedCachedHashes() -> [String: Set<String>] {
        var hashes: [String: Set<String>] = [:]
        let persisted = Set(startup.config.backend.modelAutopilot.selectedModels)
        for model in startup.autopilotInventory where !persisted.contains(model.id) {
            if let hash = model.weightHash, !hash.isEmpty { hashes[model.id, default: []].insert(hash) }
        }
        if let path = startup.configPath {
            let ledger = AutopilotDownloadLedger.read(
                from: AutopilotDownloadLedger.url(configDirectory: path.deletingLastPathComponent()))
            for (id, hash) in ledger.weightHashes { hashes[id, default: []].insert(hash) }
        }
        return hashes
    }
}
