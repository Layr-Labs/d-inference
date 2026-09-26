import Foundation
import ProviderCore

/// Keeps manual startup overrides until the durable selection changes. Only
/// model selection is live across scheduled windows; all other inputs stay frozen.
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
        resolveLocalPath: (String) -> URL? = { ModelScanner.resolveLocalPath(modelID: $0) }
    ) throws -> ProviderLoopConfig {
        guard hasOpenedWindow else {
            hasOpenedWindow = true
            return startup
        }
        guard let path = startup.configPath else { return startup }
        if !hasSeenConfigFile, !FileManager.default.fileExists(atPath: path.path) {
            return startup
        }
        let saved = try ConfigManager.load(from: path).backend.enabledModels
        hasSeenConfigFile = true
        usesSavedSelection = usesSavedSelection || saved != startup.config.backend.enabledModels
        guard usesSavedSelection else { return startup }

        // Capture BEFORE scan's weight hashing, as in attachWeightHashes. A
        // concurrent file change must force re-hashing, never bless stale bytes.
        var fingerprints: [String: String] = [:]
        for id in saved {
            if let snapshot = resolveLocalPath(id),
                let fingerprint = WeightHasher.snapshotFingerprint(snapshotDir: snapshot) {
                fingerprints[id] = fingerprint
            }
        }
        let models = try resolveModels(saved, startup.runtimeCapabilities)
        let hashes = Dictionary(uniqueKeysWithValues: models.compactMap { model in
            model.weightHash.map { (model.id, $0) }
        })
        var config = startup.config
        config.backend.enabledModels = saved
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
            configPath: path
        )
    }
}

