import Foundation

/// Every registered model the runtime can load as two layer stages, across
/// families. What a launcher or qualification tool may ask for before any
/// load; never a capability record and never an admission. Pure metadata: no
/// model, no checkpoint payload and no GPU.
public enum RegisteredResidentModels {
    public typealias Model = QwenResidentCapabilityMetadata.RegisteredModel

    /// The closed resident rows of every family, the Qwen catalog first.
    public static var all: [Model] {
        QwenResidentCapabilityMetadata.registeredModels + Gemma4RegisteredSpecification.all.map(Model.init)
    }

    /// One line per registered model and the cuts it may be loaded at, for a
    /// tool's usage text: read from the catalogs, so it cannot fall behind them.
    public static var registeredCutsUsage: String {
        all.map { "\($0.runtimeModelID): " + $0.supportedCuts.map(String.init).joined(separator: "|") }
            .joined(separator: "\n")
    }

    /// Nil for every ID that is not a registered resident model.
    public static func registeredModel(runtimeModelID: String) -> Model? {
        all.first { $0.runtimeModelID == runtimeModelID }
    }

    /// The identities a worker's `ClusterWorkerIdentity` carries for a model.
    struct Identity {
        let runtimeModelID: String
        let artifactSHA256: String
        let configurationSHA256: String
    }

    /// The registered model an artifact's own two metadata files belong to. A
    /// Gemma configuration is shared by two catalog entries, so its manifest
    /// decides; a Qwen configuration names its model alone, as it always has.
    static func identity(configuration: Data, manifest: Data) throws -> Identity {
        if Gemma4RegisteredSpecification.isRegistered(configuration: configuration) {
            let row = try Gemma4RegisteredSpecification.registered(configuration: configuration, manifest: manifest)
            return .init(runtimeModelID: row.model.rawValue, artifactSHA256: row.artifactSHA256,
                         configurationSHA256: row.configurationSHA256)
        }
        let row = try QwenResidentModelDefinition(configuration: configuration).specification
        return .init(runtimeModelID: row.model.rawValue, artifactSHA256: row.artifactSHA256,
                     configurationSHA256: row.configurationSHA256)
    }

    public static func registeredModel(configuration: Data, manifest: Data) throws -> Model {
        let row = try identity(configuration: configuration, manifest: manifest)
        guard let model = registeredModel(runtimeModelID: row.runtimeModelID) else {
            throw ProbeError("The artifact is not a registered resident model's")
        }
        return model
    }

    /// The registered model of the artifact in a directory, read from its
    /// `config.json` and `manifest.json`.
    public static func registeredModel(modelDirectory: URL) throws -> Model {
        try registeredModel(
            configuration: BoundedProbeInput.data(modelDirectory.appendingPathComponent("config.json"),
                                                  maximumBytes: 1_048_576),
            manifest: BoundedProbeInput.data(modelDirectory.appendingPathComponent("manifest.json"),
                                             maximumBytes: 4_194_304))
    }
}
