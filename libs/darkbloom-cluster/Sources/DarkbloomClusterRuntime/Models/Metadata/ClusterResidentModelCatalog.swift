import DarkbloomClusterProtocol
import Foundation

/// Every registered resident model of this build, whichever adapter executes
/// it, as a launcher or qualification tool may ask about it before any load.
/// Each entry is read from that adapter's own closed catalog; this type adds
/// no model and no second list of identities. It is the one place a caller
/// outside the runtime chooses an adapter, by the family of the entry it got.
public enum ClusterResidentModelCatalog {
    /// The runtime that executes a family's models. `qwenDense` is the
    /// layer-stage resident runtime: the Qwen catalog (dense, routed-expert,
    /// Prism and Nemotron rows) and Gemma 4 through its own layer-stage seam.
    public enum Family: String, Sendable { case qwenDense, gptoss, mimoV26 }

    public struct Entry: Equatable, Sendable {
        public let family: Family
        public let adapterID: String
        public let runtimeModelID: String
        public let profileID: String
        public let layerCount: Int
        public let supportedCuts: [Int]
        public let supportedPrefillSchedules: [ClusterPrefillSchedule]
        public let supportedGenerationModes: [ClusterGenerationMode]
        /// The longest lifetime one worker session of this model may be given.
        public let maximumLifetimeSeconds: Int
        public let configurationSHA256: String
        public let manifestSHA256: String
    }

    /// The protocol's adapter for a runtime row. A row whose model the protocol
    /// does not register cannot be described in a capability and is not listed.
    private static func entry(_ model: QwenResidentCapabilityMetadata.RegisteredModel,
                              _ specification: QwenDenseRegisteredSpecification) -> Entry? {
        guard let adapter = ClusterRuntimeAdapter.registering(runtimeModelID: model.runtimeModelID) else { return nil }
        return .init(family: .qwenDense, adapterID: adapter.rawValue,
            runtimeModelID: model.runtimeModelID, profileID: model.profileID, layerCount: model.layerCount,
            supportedCuts: model.supportedCuts, supportedPrefillSchedules: model.supportedPrefillSchedules,
            supportedGenerationModes: model.supportedGenerationModes,
            maximumLifetimeSeconds: Int(QwenResidentAdapterDefinition.maximumLifetimeNanoseconds / 1_000_000_000),
            configurationSHA256: specification.configurationSHA256, manifestSHA256: specification.manifestSHA256)
    }

    private static func entry(_ specification: Gemma4RegisteredSpecification) -> Entry? {
        let model = QwenResidentCapabilityMetadata.RegisteredModel(specification)
        guard let adapter = ClusterRuntimeAdapter.registering(runtimeModelID: model.runtimeModelID) else { return nil }
        return .init(family: .qwenDense, adapterID: adapter.rawValue,
            runtimeModelID: model.runtimeModelID, profileID: model.profileID, layerCount: model.layerCount,
            supportedCuts: model.supportedCuts, supportedPrefillSchedules: model.supportedPrefillSchedules,
            supportedGenerationModes: model.supportedGenerationModes,
            maximumLifetimeSeconds: Int(QwenResidentAdapterDefinition.maximumLifetimeNanoseconds / 1_000_000_000),
            configurationSHA256: specification.configurationSHA256, manifestSHA256: specification.manifestSHA256)
    }

    private static func entry(_ model: GPTOSSResidentCapabilityMetadata.RegisteredModel) -> Entry? {
        guard let adapter = ClusterRuntimeAdapter.registering(runtimeModelID: model.runtimeModelID) else { return nil }
        return .init(family: .gptoss, adapterID: adapter.rawValue,
            runtimeModelID: model.runtimeModelID, profileID: model.profileID, layerCount: model.layerCount,
            supportedCuts: model.supportedCuts, supportedPrefillSchedules: model.supportedPrefillSchedules,
            supportedGenerationModes: model.supportedGenerationModes,
            maximumLifetimeSeconds: model.maximumLifetimeSeconds,
            configurationSHA256: model.configurationSHA256, manifestSHA256: model.manifestSHA256)
    }

    private static func entry(_ specification: MiMoRegisteredSpecification) -> Entry? {
        guard let adapter = ClusterRuntimeAdapter.registering(runtimeModelID: specification.model.rawValue) else { return nil }
        return .init(family: .mimoV26, adapterID: adapter.rawValue,
            runtimeModelID: specification.model.rawValue, profileID: specification.profileID,
            layerCount: specification.layers, supportedCuts: specification.supportedCuts,
            supportedPrefillSchedules: specification.supportedPrefillSchedules,
            supportedGenerationModes: specification.supportedGenerationModes,
            maximumLifetimeSeconds: Int(MiMoRegisteredSpecification.maximumLifetimeNanoseconds / 1_000_000_000),
            configurationSHA256: specification.configurationSHA256, manifestSHA256: specification.manifestSHA256)
    }

    /// Each family's models in its own catalog order: the Qwen catalog first,
    /// then GPT-OSS, MiMo and Gemma 4.
    public static var all: [Entry] {
        QwenDenseRegisteredSpecification.all.compactMap { specification in
            QwenResidentCapabilityMetadata.registeredModel(runtimeModelID: specification.model.rawValue)
                .flatMap { entry($0, specification) }
        } + GPTOSSResidentCapabilityMetadata.registeredModels.compactMap { entry($0) }
          + MiMoRegisteredSpecification.all.compactMap { entry($0) }
          + Gemma4RegisteredSpecification.all.compactMap { entry($0) }
    }

    /// One line per registered model of every family and the cuts it may be
    /// loaded at, for a tool's usage text: read from the catalogs.
    public static var registeredCutsUsage: String {
        all.map { "\($0.runtimeModelID): " + $0.supportedCuts.map(String.init).joined(separator: "|") }
            .joined(separator: "\n")
    }

    /// Nil for every ID that is not a registered resident model.
    public static func entry(runtimeModelID: String) -> Entry? {
        all.first { $0.runtimeModelID == runtimeModelID }
    }

    /// The registered model an artifact's `config.json` bytes belong to. A
    /// configuration two entries share (Gemma 4 26B and its 8-bit entry) names
    /// the first of them; `describe` tells them apart by the manifest.
    public static func entry(configuration: Data) throws -> Entry {
        let digest = sha256(configuration)
        guard (1...1_048_576).contains(configuration.count),
              let value = all.first(where: { $0.configurationSHA256 == digest }) else {
            throw ProbeError("The configuration is not a registered resident model's")
        }
        return value
    }

    /// The capability record of whichever registered model the bytes belong to.
    public static func describe(configuration: Data, manifest: Data,
                                runtimeBinarySHA256: String) throws -> ClusterRuntimeCapability {
        // MiMo's bytes are known by their pin, GPT-OSS's by its own catalog.
        // Every other input is the dense producer's to describe or to refuse,
        // in its own words as before.
        if (try? MiMoRegisteredSpecification.specification(configuration: configuration)) != nil {
            return try MiMoResidentCapabilityMetadata.describe(configuration: configuration, manifest: manifest,
                                                               runtimeBinarySHA256: runtimeBinarySHA256)
        }
        if GPTOSSResidentCapabilityMetadata.handles(configuration: configuration) {
            return try GPTOSSResidentCapabilityMetadata.describe(configuration: configuration, manifest: manifest,
                                                                 runtimeBinarySHA256: runtimeBinarySHA256)
        }
        // A Gemma configuration is shared by two catalog entries; its manifest decides.
        if Gemma4ResidentCapabilityMetadata.isRegistered(configuration: configuration) {
            return try Gemma4ResidentCapabilityMetadata.describe(configuration: configuration, manifest: manifest,
                                                                 runtimeBinarySHA256: runtimeBinarySHA256)
        }
        return try QwenResidentCapabilityMetadata.describe(configuration: configuration, manifest: manifest,
                                                           runtimeBinarySHA256: runtimeBinarySHA256)
    }
}
