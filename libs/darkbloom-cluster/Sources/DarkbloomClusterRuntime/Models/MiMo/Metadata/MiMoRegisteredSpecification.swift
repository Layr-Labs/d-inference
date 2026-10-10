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
    /// Stage 0 layer counts a pair may be loaded at, ascending. Every layer
    /// boundary is a structural cut for this architecture (each layer owns its
    /// own attention state and only the residual crosses); this row lists the
    /// ones a pair of 256 GiB and 128 GiB Macs can place. A listed cut is not
    /// a memory or speed claim: the live resource gates decide each load.
    let supportedCuts: [Int]
    let supportedPrefillSchedules: [ClusterPrefillSchedule]
    /// The pipeline and its compact decode framing. No phase split: the rank
    /// that would decode alone would have to hold all `sourceBytes`, which is
    /// the single-Mac case this pair exists to avoid.
    let supportedGenerationModes: [ClusterGenerationMode]

    // Request scope, the same as the dense rows so results are comparable.
    static let maximumPromptTokens = 8192, maximumChunkTokens = 512
    static let maximumOutputTokens = 128, maximumContextTokens = 8320
    static let maximumRequests = 16

    /// A session's whole life: both loads and every request.
    ///
    /// Each rank hashes the whole 172,863,462,401-byte artifact before it reads
    /// a tensor. Hashing is one thread of SHA-256 over uncached 4 MiB reads:
    /// 92 s for this artifact on the M3 Ultra (measured 2026-10-09 by the
    /// night run's verifier), and the 27B's 16.3 GB load, which is mostly its
    /// hash, took 6.6 to 7.9 s on the M5 Max, so about 70 to 85 s there. The
    /// stage read is 110 GB on rank 0 and 57 GB on rank 1 at cut 32, one
    /// aligned read and one copy per tensor: allow up to 150 s. That is up to
    /// 250 s before a rank is ready, against the dense rows' 300 s for
    /// everything. Sixteen requests of at most 8,192 prompt and 128 output
    /// tokens at a first-proof rate of 100 prompt and 5 output tokens a second
    /// would be 108 s each, 1,728 s in all; a qualification session runs a few.
    /// 1,800 s holds the load and about fourteen such requests.
    static let maximumLifetimeNanoseconds: UInt64 = 1_800_000_000_000
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
            // Rank 1 holds 13.7 GiB at cut 44 and 105.6 GiB at cut 16; rank 0
            // holds 50.2 GiB at cut 16 and 142.0 GiB at cut 44. Which one a
            // pair can load is decided by each Mac's admissible memory when
            // the session starts, not by its size: a 128 GiB Mac in ordinary
            // desktop use had 38 to 41 GiB open (the kernel keeps about a
            // third of memory as file cache before it takes anonymous pages),
            // which is rank 1 at cut 40 (26.9 GiB) and not at cut 32 (53.1).
            // Cuts 16 and 20 are for the pair in the other order (rank 0 on
            // the smaller Mac). Twelve partitions, under the protocol's 16.
            supportedCuts: [16, 20, 24, 28, 30, 32, 34, 36, 38, 40, 42, 44],
            supportedPrefillSchedules: [.serial],
            supportedGenerationModes: [.pipeline, .pipelineCompactDecode]),
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

    func profile() throws -> QwenLayerStageGenerationProfile {
        try .init(identifier: profileID, vocabularySize: vocabulary, hiddenSize: hidden,
            activationDType: "bfloat16", maximumPromptTokens: Self.maximumPromptTokens,
            maximumChunkTokens: Self.maximumChunkTokens, maximumOutputTokens: Self.maximumOutputTokens,
            maximumContextTokens: Self.maximumContextTokens)
    }
}
