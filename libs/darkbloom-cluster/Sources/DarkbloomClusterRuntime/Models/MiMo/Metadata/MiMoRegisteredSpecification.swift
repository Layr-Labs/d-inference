import DarkbloomClusterProtocol
import Foundation

/// The MiMo artifacts the layer-pipeline adapter executes. Closed: an ID or a
/// configuration outside this enumeration has no specification.
enum MiMoRegisteredModel: String, CaseIterable {
    case v26FlashMOPD = "registered_mimo_v26_flash_mopd"
}

struct MiMoProfileError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

/// One closed row per registered MiMo artifact: its pinned identities, the
/// geometry those identities must reproduce, and the byte, time and cut scope
/// of its resident pair. Describing a model allocates nothing and admits no
/// request. Every integer here was read from the artifact's own `config.json`,
/// `manifest.json` and shard headers; `MiMoRegisteredModelProfile.admit`
/// recomputes each one from the bytes it is given and refuses a difference.
struct MiMoRegisteredSpecification {
    let model: MiMoRegisteredModel
    let profileID: String
    let configurationSHA256: String, manifestSHA256: String, artifactSHA256: String
    /// SHA-256 over the sorted `name|dtype|shape|bytes` lines of the text tensors.
    let inventorySHA256: String
    let manifestBytes: Int, manifestFileCount: Int
    /// The text tensors the two stages load between them: `language_model.*`
    /// without the embedded MTP heads.
    let sourceBytes: Int, tensorCount: Int, largestTensorBytes: Int
    /// Indexed tensors no stage loads: the MTP heads, the vision tower, the
    /// audio encoder and the speech embeddings.
    let excludedTensorCount: Int, excludedBytes: Int
    let layers: Int, hidden: Int, vocabulary: Int
    /// Layers whose attention keeps the whole history; every other layer keeps
    /// a window of `slidingWindow` positions.
    let fullAttentionLayers: [Int]
    /// Layers with a dense MLP; every other layer routes over `experts`.
    let denseFeedForwardLayers: [Int]
    let experts: Int, expertsPerToken: Int
    let slidingWindow: Int
    let fullKeyValueHeads: Int, slidingKeyValueHeads: Int, keyWidth: Int, valueWidth: Int
    /// `max_position_embeddings` of the pinned configuration; the request
    /// limits follow from it (`contextLimits`).
    let declaredContextTokens: Int
    /// Stage 0 layer counts a pair may be loaded at, ascending: every layer
    /// boundary, each a structural cut for this architecture (each layer owns
    /// its own attention state and only the residual crosses). Not a memory
    /// or speed claim: the planner chooses from what each Mac detects and the
    /// live resource gates decide each load. Rank 1 holds 13.7 GiB at cut 44
    /// and 105.6 GiB at cut 16; rank 0 50.2 GiB at cut 16 and 142.0 GiB at 44.
    /// The row once listed twelve the pair it was written on could place.
    var supportedCuts: [Int] { Array(1..<layers) }
    /// Serial, and the one-chunk lookahead (rank 0 prefills the next frame
    /// while rank 1 runs the current one; state is per request and frame-ordered).
    let supportedPrefillSchedules: [ClusterPrefillSchedule]
    /// The pipeline, its compact decode framing, the phase split and the
    /// pipeline with the artifact's own three next-N heads on the last rank
    /// (`pipeline_mtp_v1`: decode as speculative rounds, `MiMoMTPGeneration`).
    /// The phase split is a hand-off mode (kept, off by default; a planner
    /// considers it only behind the explicit opt-in): its decoding rank holds
    /// every layer (all `sourceBytes`) and decodes alone after the other rank
    /// prefilled its share and handed its state over, or serves a request alone.
    /// Whether a Mac can hold every layer is the planner's and the load gate's
    /// question on the Macs at hand, not this row's.
    let supportedGenerationModes: [ClusterGenerationMode]

    // The earlier fixed reservation every profile started with; the row's
    // limits now follow from the context it declares (`contextLimits`).
    static let maximumPromptTokens = 8192, maximumChunkTokens = 512
    static let maximumOutputTokens = 128, maximumContextTokens = 8320

    // No session lifetime and no request count (removed 2026-10-10): a rank
    // is kept on its renewable rank lease while its owner wants it resident.
    // Loading is bounded by the startup deadline below, not by a lifetime.
    /// Files hashed at once when a rank verifies the artifact. One thread took
    /// 62.4 s on the M5 Max for all 172.9 GB (2.8 GB/s, the speed of one core's
    /// SHA-256); six are bounded by the disk instead. The dense rows keep one.
    static let hashingConcurrency = 6
    /// A rank that is not ready this long after it started is gone: the hash
    /// and load above with a fifth to spare. Named for a launcher; the worker
    /// enforces whatever startup deadline it is given.
    static let startupSeconds = 300

    var maximumManifestPayloadBytes: Int { manifestBytes }
    /// No stage of any listed cut holds more than the text model.
    var maximumStageTensorBytes: Int { sourceBytes }

    static let all: [Self] = [
        .init(model: .v26FlashMOPD, profileID: "registered_mimo_v26_flash_mopd_greedy_generation_v1",
            configurationSHA256: "35b6e3d4543b65e6fa9d6174e2260d9ac1d3ea1e5acb9955d9fe9f2b815d13d4",
            manifestSHA256: "de1bd701115a9ee7e4a99ac85307b31285c63a0b0b1c22ef0c69e9b4ac10f346",
            artifactSHA256: "2334547d8acc9898ad4a74570ce44d2b12390bbac8d4bc52c092eb5ad5cfe034",
            inventorySHA256: "284eb2366eb7aacec0aa8362f54d195312bd2d0c2f68b3f7069e8a80add6d7d5",
            manifestBytes: 172_863_462_401, manifestFileCount: 53,
            sourceBytes: 167_264_120_704, tensorCount: 1103, largestTensorBytes: 1_073_741_824,
            excludedTensorCount: 629, excludedBytes: 3_710_306_688,
            layers: 48, hidden: 4096, vocabulary: 152_576,
            fullAttentionLayers: [0, 5, 11, 17, 23, 29, 35, 41, 47], denseFeedForwardLayers: [0],
            experts: 256, expertsPerToken: 8, slidingWindow: 128,
            fullKeyValueHeads: 4, slidingKeyValueHeads: 8, keyWidth: 192, valueWidth: 128,
            declaredContextTokens: 1_048_576,
            supportedPrefillSchedules: [.serial, .oneChunkLookahead],
            supportedGenerationModes: [.pipeline, .pipelineCompactDecode, .phaseSplit, .pipelineMTP]),
    ]

    static func specification(_ model: MiMoRegisteredModel) throws -> Self {
        guard let value = all.first(where: { $0.model == model }) else {
            throw MiMoProfileError("Registered MiMo model has no specification")
        }
        return value
    }

    /// The `modelID` of a worker identity. Anything else is refused.
    static func specification(runtimeModelID: String) throws -> Self {
        guard let model = MiMoRegisteredModel(rawValue: runtimeModelID) else {
            throw MiMoProfileError("Model ID is not a registered MiMo resident model")
        }
        return try specification(model)
    }

    /// The registered model whose pinned configuration these bytes are.
    static func specification(configuration: Data) throws -> Self {
        let digest = sha256(configuration)
        guard (1...1_048_576).contains(configuration.count),
              let value = all.first(where: { $0.configurationSHA256 == digest }) else {
            throw MiMoProfileError("Configuration is not a registered MiMo resident model's")
        }
        return value
    }

    /// The request bounds: the protocol's, cut to the declared context, as
    /// the dense Qwen rows derive theirs (`QwenResidentContextLimits`).
    func contextLimits() throws -> QwenResidentContextLimits {
        try QwenResidentContextLimits(declaredContextTokens: declaredContextTokens)
    }

    func profile(imageCandidate: Bool = false) throws -> QwenLayerStageGenerationProfile {
        let limits = try contextLimits()
        return try .init(identifier: imageCandidate ? ClusterMiMoImageCandidate.profileID : profileID, vocabularySize: vocabulary, hiddenSize: hidden,
            activationDType: "bfloat16", maximumPromptTokens: limits.maximumPromptTokens,
            maximumChunkTokens: limits.maximumChunkTokens, maximumOutputTokens: limits.maximumOutputTokens,
            maximumContextTokens: limits.maximumContextTokens)
    }
}
