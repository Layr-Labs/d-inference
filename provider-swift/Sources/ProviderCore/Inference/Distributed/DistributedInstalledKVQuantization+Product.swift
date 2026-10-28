// Copyright © 2026 Eigen Labs.

import Foundation

/// The pair's live KV precision resolver from the product's policy types:
/// the saved `[backend]` settings and the single-Mac resolution
/// (`EngineV2KVQuantizationPolicy.resolve`), nothing cluster-specific.
extension DistributedInstalledKVQuantization {
    /// Resolve from the saved provider configuration at `url` and install for
    /// this owner process: the live precision and the SSD records' checkpoint
    /// precision. `cluster worker-owner` has just read the same file for its
    /// cluster reference and stops when it cannot; a later failure here leaves
    /// main's defaults with the owner's switches.
    public static func installProduct(providerConfiguration url: URL) {
        let backend = (try? savedBackendSettings(providerConfiguration: url)) ?? BackendSettings()
        install(resolver(backend: backend))
        installRecords(recordsResolver(backend: backend))
    }

    /// Main's resolution for one public model ID: the switch, then the per-model
    /// and global settings; nil for native. A setting main would refuse is
    /// passed on as its bounded name, for the rank to refuse by name.
    static func resolver(backend: BackendSettings) -> Resolver {
        let global = backend.engineV2KVQuantization, byModel = backend.engineV2KVQuantizationByModel
        return { modelID, environment in
            do {
                let selection = try EngineV2KVQuantizationPolicy.resolve(modelType: nil, global: global,
                    byModel: byModel, modelID: modelID, environment: environment)
                return selection == .native ? nil : selection.rawValue
            } catch {
                return boundedName(environment[switchName] ?? byModel[modelID] ?? global)
            }
        }
    }

    /// Main's checkpoint resolution for one public model ID, the precision of
    /// the pair's SSD prompt-prefix records: the switch, then the per-model and
    /// global checkpoint settings, `balanced` by default. Always a name, native
    /// included; a setting main would refuse is passed on as its bounded name.
    static func recordsResolver(backend: BackendSettings) -> Resolver {
        let global = backend.engineV2KVCheckpointQuantization, byModel = backend.engineV2KVCheckpointQuantizationByModel
        return { modelID, environment in
            do {
                return try EngineV2KVQuantizationPolicy.resolve(modelType: nil, global: global, byModel: byModel,
                    modelID: modelID, environment: environment, purpose: .checkpoint).rawValue
            } catch {
                return boundedName(environment[checkpointSwitchName] ?? byModel[modelID] ?? global)
            }
        }
    }

    /// The saved backend settings of the provider configuration at `url`
    /// (bounded, private-mode read; the defaults when there is no file).
    static func savedBackendSettings(providerConfiguration url: URL) throws -> BackendSettings {
        var info = stat()
        if lstat(url.path, &info) != 0, errno == ENOENT { return BackendSettings() }
        let bytes = try ClusterConfigurationFiles.read(url, maximum: 1_048_576, privateMode: true)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw ClusterConfigurationError.invalid("Provider configuration is not UTF-8")
        }
        return try ConfigManager.parseValidating(text).backend
    }
}
