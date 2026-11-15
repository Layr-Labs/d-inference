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

/// How a registered artifact's `config.json` quantizes the text model: its
/// `quantization` (and identical `quantization_config`) table, held entry by
/// entry (`Gemma4StageGeometry.decode`). Every projection is affine.
enum Gemma4QuantizationLayout: Equatable {
    /// `defaultBits` in groups of 64; only the shared feed-forward and router
    /// projections are named, at 8 bits in groups of 64: the 8-bit artifact
    /// (8), and the QAT 4-bit revision `2026-06-08-r1` before it (4).
    case sharedFeedForwardAt8(defaultBits: Int)
    /// The QAT lattice revision `2026-11-13-qat-lattice8-r1` of
    /// `gemma-4-26b-qat-4bit` ("Gemma C"): every projection is named. The
    /// routed experts keep the QAT checkpoint's 4-bit lattice in groups of 32;
    /// attention, the shared feed-forward, the router, the tied embedding and
    /// the vision embedding are at 8 bits in groups of 64. No projection is
    /// left to the table's defaults (4, 64).
    case qatLattice

    struct Entry: Equatable {
        let bits: Int, groupSize: Int
    }

    /// The defaults of the table: what a projection it does not name is.
    var defaults: Entry {
        switch self {
        case .sharedFeedForwardAt8(let bits): return .init(bits: bits, groupSize: 64)
        case .qatLattice: return .init(bits: 4, groupSize: 64)
        }
    }

    /// Every projection the table names, by its path in the whole model.
    var named: [String: Entry] {
        let eight = Entry(bits: 8, groupSize: 64)
        var result: [String: Entry] = [:]
        for layer in 0..<Gemma4StageGeometry.layerCount {
            let root = Gemma4LayerStagePlanning.layerRoot(layer) + "."
            for module in ["mlp.gate_proj", "mlp.up_proj", "mlp.down_proj", "router.proj"] { result[root + module] = eight }
            guard self == .qatLattice else { continue }
            var attention = ["self_attn.q_proj", "self_attn.k_proj", "self_attn.o_proj"]
            // Full-attention layers reuse the key projection for values.
            if !Gemma4StageGeometry.isFullAttention(globalLayerIndex: layer) { attention.append("self_attn.v_proj") }
            for module in attention { result[root + module] = eight }
            for module in ["experts.switch_glu.gate_proj", "experts.switch_glu.up_proj", "experts.switch_glu.down_proj"] {
                result[root + module] = .init(bits: 4, groupSize: 32)
            }
        }
        if self == .qatLattice {
            result[Gemma4LayerStagePlanning.embeddingModule] = eight
            result["embed_vision.embedding_projection"] = eight
        }
        return result
    }
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
    /// How the configuration quantizes each projection.
    let quantization: Gemma4QuantizationLayout

    /// Bits of every projection the configuration does not name.
    var defaultQuantizationBits: Int { quantization.defaults.bits }

    private init(model: Gemma4RegisteredModel, catalogModelID: String, configurationSHA256: String,
                 manifestSHA256: String, artifactSHA256: String, inventorySHA256: String,
                 manifestBytes: Int, manifestFileCount: Int, sourceBytes: Int, tensorCount: Int,
                 largestTensorBytes: Int, quantization: Gemma4QuantizationLayout) {
        self.model = model; self.catalogModelID = catalogModelID
        self.configurationSHA256 = configurationSHA256; self.manifestSHA256 = manifestSHA256
        self.artifactSHA256 = artifactSHA256; self.inventorySHA256 = inventorySHA256
        self.manifestBytes = manifestBytes; self.manifestFileCount = manifestFileCount
        self.sourceBytes = sourceBytes; self.tensorCount = tensorCount
        self.largestTensorBytes = largestTensorBytes; self.quantization = quantization
    }

    private static let eightBitConfigurationSHA256 = "1b318c90eed55cc01711dbcae4ab7604dc6f785de59b20458f9b49017c7c9cae"
    private static let eightBitArtifactSHA256 = "a4722b6020adb1894c700b45ddcd58bc0e0f033abe7139f86cbbbfe60cba4eb6"
    private static let eightBitInventorySHA256 = "fc2b641d5de1240441b165f559fe69fcdfc074be6e5ed1a8bbc12eb5a6381207"

    private static func eightBit(_ model: Gemma4RegisteredModel, catalogModelID: String, manifestSHA256: String) -> Self {
        .init(model: model, catalogModelID: catalogModelID, configurationSHA256: eightBitConfigurationSHA256,
            manifestSHA256: manifestSHA256, artifactSHA256: eightBitArtifactSHA256,
            inventorySHA256: eightBitInventorySHA256, manifestBytes: 27_986_040_506, manifestFileCount: 13,
            sourceBytes: 26_810_869_820, tensorCount: 1339, largestTensorBytes: 738_197_504,
            quantization: .sharedFeedForwardAt8(defaultBits: 8))
    }

    /// `gemma-4-26b-qat-4bit` is the QAT lattice revision `2026-11-13-qat-lattice8-r1` ("Gemma C"), the production
    /// catalog's revision since 2026-11-14. It replaced `2026-06-08-r1` (aggregate `2468a0cb…`, configuration
    /// `29910322…`, manifest `e1bd0a99…`, 4/64 with the shared feed-forward and router at 8/64): a catalog entry has
    /// one registered artifact, which every closed list of the runtime and its tools pins.
    static let all: [Self] = [
        .init(model: .twentySixBQAT4Bit, catalogModelID: "gemma-4-26b-qat-4bit",
            configurationSHA256: "904fb35a8a6b06c1634daf194f8d9b0e24fd6c433caaa1a42da72a34e2505ddc",
            manifestSHA256: "f300d38f819172bd57464fd158d1ee77a322b7da8a327dd1b5a646d9471a36ee",
            artifactSHA256: "6aee23b20b8adfe05a4fdf2c13fdd0959de379dd3ddeff9497c717c8a92a1e5e",
            inventorySHA256: "831c84977e2c110118ba641da688e09de7eeb41e24ec715b54fe28622351bc6f",
            manifestBytes: 17_994_477_744, manifestFileCount: 11, sourceBytes: 16_819_251_260,
            tensorCount: 1339, largestTensorBytes: 738_197_504, quantization: .qatLattice),
        eightBit(.twentySixB, catalogModelID: "gemma-4-26b",
            manifestSHA256: "534b6e9eb9c4f93c24f12e191e022865388c124f8021c213852cc3c2d51f795c"),
        eightBit(.twentySixB8Bit, catalogModelID: "gemma-4-26b-8bit",
            manifestSHA256: "84b34231bc57b36a2d412f2fb0608a7828437915806241ca212b30912ceabbbb"),
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
