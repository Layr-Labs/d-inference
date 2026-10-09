import DarkbloomClusterProtocol
import Foundation

struct GPTOSSProfileError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

/// The GPT-OSS models the layer-stage adapter executes. Selection is by this
/// enumeration only: an ID outside it has no specification and cannot be
/// admitted, described or loaded.
enum GPTOSSRegisteredModel: String, CaseIterable {
    case twentyB = "registered_gpt_oss_20b"
}

/// Closed retained identity of one registered GPT-OSS artifact, with the
/// geometry and the resident scope the adapter admits for it. Every integer is
/// read from the artifact's own configuration and tensor headers and pinned
/// here; admission recomputes each one and refuses a difference. Describing a
/// model allocates nothing and admits no request.
struct GPTOSSRegisteredSpecification {
    let model: GPTOSSRegisteredModel
    let profileID: String
    /// The catalog entry the pins were read from.
    let catalogModelID: String, catalogVersion: String
    let configurationSHA256: String, manifestSHA256: String, artifactSHA256: String
    /// SHA-256 over every stored tensor's `name|dtype|shape|bytes`, by name.
    let inventorySHA256: String
    let manifestBytes: Int, manifestFileCount: Int
    let sourceBytes: Int, tensorCount: Int, largestTensorBytes: Int
    let layers: Int, hidden: Int, intermediate: Int, vocabulary: Int
    let experts: Int, expertsPerToken: Int
    let queryHeads: Int, keyValueHeads: Int, headDimension: Int, slidingWindow: Int
    let maximumPositions: Int
    /// Stage 0 layer counts a pair may be loaded at, ascending. Any cut is
    /// structurally legal because the configuration names every layer's type;
    /// this row is the scope that has been proven, not a memory or speed claim.
    let supportedCuts: [Int]
    let supportedPrefillSchedules: [ClusterPrefillSchedule]
    /// The pipeline and its compact decode framing. The phase split is absent:
    /// its hand-off cannot carry a sliding-window layer's rows.
    let supportedGenerationModes: [ClusterGenerationMode]

    static let maximumLifetimeNanoseconds: UInt64 = 300_000_000_000
    static let maximumRequests = 16
    static let maximumPromptTokens = 8192, maximumChunkTokens = 512
    static let maximumOutputTokens = 128, maximumContextTokens = 8320
    static let activationDType = "bfloat16"
    static let slidingAttention = "sliding_attention", fullAttention = "full_attention"

    static let all: [Self] = [
        .init(model: .twentyB, profileID: "registered_gpt_oss_20b_greedy_generation_v1",
            catalogModelID: "gpt-oss-20b", catalogVersion: "2026-05-25-r1",
            configurationSHA256: "d1c1f73bf62116ed0bb37c068af80534543cd1de9b61d609fc01bf70920e842d",
            manifestSHA256: "a66dc823dd0cea6710be6bb7a84a8b9f78454a1893a76dcd7a9d4e5ba861a996",
            artifactSHA256: "61bfc04e4016a7fa487eb10e29f79360047e302487229f298da3681984aec512",
            inventorySHA256: "eb0ae091bd96dec62e14d162c4ac1e26b8a66a90d3141d16d06bc06abffe1c8b",
            manifestBytes: 12_104_215_835, manifestFileCount: 10,
            sourceBytes: 12_076_119_168, tensorCount: 775, largestTensorBytes: 579_133_440,
            layers: 24, hidden: 2880, intermediate: 2880, vocabulary: 201_088,
            experts: 32, expertsPerToken: 4, queryHeads: 64, keyValueHeads: 8, headDimension: 64,
            slidingWindow: 128, maximumPositions: 131_072,
            supportedCuts: [6, 8, 10, 12],
            supportedPrefillSchedules: [.serial, .oneChunkLookahead],
            supportedGenerationModes: [.pipeline, .pipelineCompactDecode]),
    ]

    /// The `modelID` of a worker identity. Anything but a registered ID is refused.
    static func specification(runtimeModelID: String) throws -> Self {
        guard let model = GPTOSSRegisteredModel(rawValue: runtimeModelID),
              let value = all.first(where: { $0.model == model }) else {
            throw GPTOSSProfileError("Model ID is not a registered GPT-OSS resident model")
        }
        return try value.validated()
    }

    /// The registered model whose pinned configuration these bytes are.
    static func specification(configuration: Data) throws -> Self {
        let digest = sha256(configuration)
        guard (1...1_048_576).contains(configuration.count),
              let value = all.first(where: { $0.configurationSHA256 == digest }) else {
            throw GPTOSSProfileError("Configuration is not a registered GPT-OSS resident model's")
        }
        return try value.validated()
    }

    static func handles(configuration: Data) -> Bool { (try? specification(configuration: configuration)) != nil }
    static func handles(runtimeModelID: String) -> Bool { GPTOSSRegisteredModel(rawValue: runtimeModelID) != nil }

    /// The row's own consistency, checked every time it is taken.
    private func validated() throws -> Self {
        let legal = Array(1..<layers)
        guard !supportedCuts.isEmpty, supportedCuts == Array(Set(supportedCuts)).sorted(),
              supportedCuts.allSatisfy(legal.contains),
              supportedPrefillSchedules.first == .serial,
              supportedPrefillSchedules == ClusterPrefillSchedule.allCases.filter(supportedPrefillSchedules.contains),
              supportedGenerationModes.first == .pipeline,
              supportedGenerationModes == ClusterGenerationMode.allCases.filter(supportedGenerationModes.contains),
              !supportedGenerationModes.contains(.phaseSplit),
              [configurationSHA256, manifestSHA256, artifactSHA256, inventorySHA256].allSatisfy(qwenStageWireIsSHA256),
              queryHeads % keyValueHeads == 0, Self.maximumContextTokens <= maximumPositions else {
            throw GPTOSSProfileError("Registered GPT-OSS row is inconsistent")
        }
        return self
    }

    /// The pinned manifest must state the registered totals and this configuration.
    func requireManifest(_ manifest: Data, configuration: Data) throws {
        struct Manifest: Decodable {
            struct Entry: Decodable { let path: String, sha256: String; let size_bytes: Int }
            let aggregate_sha256: String, file_count: Int, total_size_bytes: Int, files: [Entry]
        }
        guard sha256(manifest) == manifestSHA256, sha256(configuration) == configurationSHA256,
              let declared = try? JSONDecoder().decode(Manifest.self, from: manifest),
              declared.aggregate_sha256 == artifactSHA256, declared.file_count == manifestFileCount,
              declared.files.count == declared.file_count, Set(declared.files.map(\.path)).count == declared.file_count,
              declared.total_size_bytes == manifestBytes,
              declared.files.allSatisfy({ $0.size_bytes >= 0 }),
              declared.files.reduce(0, { $0 + $1.size_bytes }) == manifestBytes,
              declared.files.first(where: { $0.path == "config.json" })?.sha256 == configurationSHA256 else {
            throw GPTOSSProfileError("Pinned GPT-OSS manifest and configuration semantics differ")
        }
    }

    func profile() throws -> QwenLayerStageGenerationProfile {
        try .init(identifier: profileID, vocabularySize: vocabulary, hiddenSize: hidden,
            activationDType: Self.activationDType, maximumPromptTokens: Self.maximumPromptTokens,
            maximumChunkTokens: Self.maximumChunkTokens, maximumOutputTokens: Self.maximumOutputTokens,
            maximumContextTokens: Self.maximumContextTokens)
    }
}
