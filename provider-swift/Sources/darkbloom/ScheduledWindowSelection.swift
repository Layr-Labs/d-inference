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
        let inventoryIDs = savedBackend.modelAutopilot.hasConsent ? savedBackend.modelAutopilot.selectedModels : []
        let combinedIDs = selectedIDs + inventoryIDs.filter { !selectedIDs.contains($0) }

        // Capture BEFORE scan's weight hashing, as in attachWeightHashes. A
        // concurrent file change must force re-hashing, never bless stale bytes.
        var fingerprints: [String: String] = [:]
        for id in combinedIDs {
            if let snapshot = resolveLocalPath(id),
                let fingerprint = WeightHasher.snapshotFingerprint(snapshotDir: snapshot) {
                fingerprints[id] = fingerprint
            }
        }
        let verified = try resolveModels(combinedIDs, startup.runtimeCapabilities)
        let models = verified.filter { selectedIDs.contains($0.id) }
        let hashes = Dictionary(uniqueKeysWithValues: verified.compactMap { model in
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
            autopilotInventory: verified.filter { inventoryIDs.contains($0.id) && $0.weightHash?.isEmpty == false }
        )
    }
}
