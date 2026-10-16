import Foundation

/// The registered Gemma 4 26B artifacts, one closed case per catalog entry.
/// `gemma-4-26b` and `gemma-4-26b-8bit` are one artifact published under two
/// manifests: they share a configuration, an aggregate and a tensor inventory
/// and differ only in the manifest a rank pins.
enum Gemma4RegisteredModel: String, Codable, CaseIterable {
    case twentySixBQAT4Bit = "registered_gemma4_26b_qat_4bit"
    case twentySixB = "registered_gemma4_26b"
    case twentySixB8Bit = "registered_gemma4_26b_8bit"
}

/// Closed retained identities, not a model registry or provider allowlist.
/// Every value was read from the artifact's own `config.json`, `manifest.json`
/// and safetensors headers. The private initializer is used only below.
struct Gemma4RegisteredSpecification {
    let model: Gemma4RegisteredModel
    /// The catalog entry whose manifest this row pins.
    let catalogModelID: String
    let configurationSHA256: String, manifestSHA256: String, artifactSHA256: String
    /// Fingerprint of the text tensors' `name|dtype|shape|bytes` lines in name order.
    let inventorySHA256: String
    let manifestBytes: Int, manifestFileCount: Int
    /// The `language_model.` tensors only; the vision tower is never read.
    let sourceBytes: Int, tensorCount: Int, largestTensorBytes: Int
    /// Bits of every projection the configuration does not name. The shared
    /// feed-forward and router projections are named, at 8 bits, in both artifacts.
    let defaultQuantizationBits: Int

    private init(model: Gemma4RegisteredModel, catalogModelID: String, configurationSHA256: String,
                 manifestSHA256: String, artifactSHA256: String, inventorySHA256: String,
                 manifestBytes: Int, manifestFileCount: Int, sourceBytes: Int, tensorCount: Int,
                 largestTensorBytes: Int, defaultQuantizationBits: Int) {
        self.model = model; self.catalogModelID = catalogModelID
        self.configurationSHA256 = configurationSHA256; self.manifestSHA256 = manifestSHA256
        self.artifactSHA256 = artifactSHA256; self.inventorySHA256 = inventorySHA256
        self.manifestBytes = manifestBytes; self.manifestFileCount = manifestFileCount
        self.sourceBytes = sourceBytes; self.tensorCount = tensorCount
        self.largestTensorBytes = largestTensorBytes; self.defaultQuantizationBits = defaultQuantizationBits
    }

    private static let eightBitConfigurationSHA256 = "1b318c90eed55cc01711dbcae4ab7604dc6f785de59b20458f9b49017c7c9cae"
    private static let eightBitArtifactSHA256 = "a4722b6020adb1894c700b45ddcd58bc0e0f033abe7139f86cbbbfe60cba4eb6"
    private static let eightBitInventorySHA256 = "fc2b641d5de1240441b165f559fe69fcdfc074be6e5ed1a8bbc12eb5a6381207"

    private static func eightBit(_ model: Gemma4RegisteredModel, catalogModelID: String, manifestSHA256: String) -> Self {
        .init(model: model, catalogModelID: catalogModelID, configurationSHA256: eightBitConfigurationSHA256,
            manifestSHA256: manifestSHA256, artifactSHA256: eightBitArtifactSHA256,
            inventorySHA256: eightBitInventorySHA256, manifestBytes: 27_986_040_506, manifestFileCount: 13,
            sourceBytes: 26_810_869_820, tensorCount: 1339, largestTensorBytes: 738_197_504,
            defaultQuantizationBits: 8)
    }

    static let all: [Self] = [
        .init(model: .twentySixBQAT4Bit, catalogModelID: "gemma-4-26b-qat-4bit",
            configurationSHA256: "29910322dd085f45c8f95c6c0f1611b20f722d6f6c8394321b34817e98a972fa",
            manifestSHA256: "c1fefb1fa593fa3ca83e72a1124fb3afca10a59eed272c7ac2ac4a57f8018dfd",
            artifactSHA256: "2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785",
            inventorySHA256: "da7781c57eb4864913649b547e51821398813a4b9f1c61e09bcc1fb3e7cd3c08",
            manifestBytes: 15_641_239_295, manifestFileCount: 10, sourceBytes: 14_467_688_508,
            tensorCount: 1339, largestTensorBytes: 369_098_752, defaultQuantizationBits: 4),
        eightBit(.twentySixB, catalogModelID: "gemma-4-26b",
            manifestSHA256: "4d36eeed9afe33805bdccf9f59b4d455193ada96a56b4b4e346727a5879b0c9b"),
        eightBit(.twentySixB8Bit, catalogModelID: "gemma-4-26b-8bit",
            manifestSHA256: "4e4e7df6aed1964ce70d9a3334e8114d2a18593a334c2fc3e5f2dce5ae65deed"),
    ]

    static func registered(_ model: Gemma4RegisteredModel) throws -> Self {
        guard let row = all.first(where: { $0.model == model }) else {
            throw ProbeError("Registered Gemma model has no specification")
        }
        return row
    }

    /// The `modelID` of a worker identity. Anything but a registered ID is refused.
    static func registered(runtimeModelID: String) throws -> Self {
        guard let model = Gemma4RegisteredModel(rawValue: runtimeModelID) else {
            throw ProbeError("Model ID is not a registered Gemma model")
        }
        return try registered(model)
    }

    /// The row an artifact's own two metadata files select. Two rows share one
    /// configuration, so the manifest decides; both must match the same row.
    static func registered(configuration: Data, manifest: Data) throws -> Self {
        guard (1...1_048_576).contains(configuration.count), (1...4_194_304).contains(manifest.count) else {
            throw ProbeError("Gemma metadata exceeds its bounded input scope")
        }
        let manifestSHA256 = sha256(manifest), configurationSHA256 = sha256(configuration)
        guard let row = all.first(where: { $0.manifestSHA256 == manifestSHA256 }),
              row.configurationSHA256 == configurationSHA256 else {
            throw ProbeError("Configuration and manifest are not a registered Gemma artifact's")
        }
        return row
    }

    /// Whether these configuration bytes belong to any registered Gemma row.
    static func isRegistered(configuration: Data) -> Bool {
        let digest = sha256(configuration)
        return all.contains { $0.configurationSHA256 == digest }
    }
}
