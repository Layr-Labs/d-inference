import Foundation
import DarkbloomClusterProtocol

/// One model whose clusters serve public traffic (`ClusterPublicModels`), with
/// the placement its public qualification ran.
public struct ClusterPublicModel: Sendable, Equatable {
    /// The runtime's own model identity (the worker's registered model).
    public let runtimeModelID: String
    /// The catalog model ID the owner declared: a release's facts carry the
    /// qualifications under this ID only.
    public let catalogModelID: String
    /// The artifact the runtime registers for the model, which the evidence ran.
    public let artifactSHA256: String
    /// The placement each declared mode family was qualified on.
    public let placements: [Placement]
    /// The prefill schedules qualified: 1 serial, 2 one-chunk lookahead.
    public let schedules: [UInt8]

    /// Every rank on one GPU architecture and macOS version, the layer cuts and
    /// the generation mode; layers shared equally.
    public struct Placement: Sendable, Equatable {
        public let mode: ClusterGenerationMode
        public let ranks: Int
        /// Metal's architecture name of each rank's GPU (`applegpu_g17d`: Apple M5 Ultra).
        public let gpuArchitecture: String
        public let macOSMajor: Int
        public let macOSMinor: Int
        public let cuts: [Int]

        public var family: ClusterPairServingModeFamily { mode.servingFamily }
    }

    /// The declared mode families, in order.
    public var families: [ClusterPairServingModeFamily] { Set(placements.map(\.family)).sorted() }
}

/// The models whose clusters serve public traffic: the owner's declaration
/// (jonathan308, 2026-10-31: "public traffic should not be manual"; "only glm
/// 5.3 flash should be serving public & qwen 3.8 27b they are both good to go
/// they should be approved for serving"), reviewed in PRs like any code. A
/// release's cluster runtime facts carry a parity qualification for each
/// declared family and schedule of these models
/// (`ClusterRuntimeApprovalFacts.parityQualifications`), from which a
/// coordinator derives the parity qualifications of their approvals; a cluster
/// of any other model serves its owner only. The evidence is
/// `evidenceDocument`, whose SHA-256 is `evidenceSHA256` (a test holds them
/// equal), so a released CLI names it without carrying the file.
public enum ClusterPublicModels {
    public static let evidenceDocument = "docs/reports/2026-10-31-public-cluster-models.md"
    public static let evidenceSHA256 = "ea78cd09cc4fe04828dce9887ff4d0bb4f535128f94355755e7e8ad21f55d57a"
    public static let qualifiedAt = "2026-10-31T00:00:00Z"
    /// A public request's prompt and output allowance: the coordinator's
    /// maximum, so only the model's own limits apply.
    public static let maximumTokens = 1_048_576

    /// Two Apple M5 Ultras (Metal `applegpu_g17d`, NAX on) on macOS 27.0, tensor parallel, equal shares.
    static let m5UltraTensorParallel = ClusterPublicModel.Placement(mode: .tensorParallel, ranks: 2,
        gpuArchitecture: "applegpu_g17d", macOSMajor: 27, macOSMinor: 0, cuts: [])

    public static let declared: [ClusterPublicModel] = [
        .init(runtimeModelID: "registered_glm53_flash", catalogModelID: "glm-5.3-flash",
              artifactSHA256: "3aae613ff188bb0f72e880774a84e4d8e9943ab20c929d8a302af9c57b97d5ac",
              placements: [m5UltraTensorParallel], schedules: [1, 2]),
        .init(runtimeModelID: "registered_qwen38_27b", catalogModelID: "EigenLabs/Qwen3.8-27B-4bit-mtp",
              artifactSHA256: "bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463",
              placements: [m5UltraTensorParallel], schedules: [1, 2]),
    ]

    /// The request shape a declared model's clusters serve publicly: sampling
    /// and tools, prompts and outputs up to the model's own limits, and media as
    /// its catalog entry in the release's environment lists it (`image` for
    /// vision, `video` as well for video). Both declared models' tensor-parallel
    /// paths take media as the single-Mac product does (`ClusterGLMMedia`,
    /// `ClusterQwenMedia`).
    public static func requestEnvelope(inputModalities: [String]) -> ClusterRequestEnvelope {
        let vision = inputModalities.contains("image")
        return .init(sampling: true, tools: true, vision: vision, video: vision && inputModalities.contains("video"),
                     maxPromptTokens: maximumTokens, maxOutputTokens: maximumTokens)
    }

    /// The families `models` declare for a runtime model's artifact (the
    /// installed one, mapped as grants map it; nil: the model's own); none for
    /// any other model or artifact.
    static func families(runtimeModelID: String, artifactSHA256: String?,
                         in models: [ClusterPublicModel] = declared) -> [ClusterPairServingModeFamily] {
        guard let model = models.first(where: { $0.runtimeModelID == runtimeModelID }),
              artifactSHA256.map({ ClusterPairServingGrants.qualifyingArtifact(for: $0, runtimeModelID: runtimeModelID)
                  == model.artifactSHA256 }) ?? true else { return [] }
        return model.families
    }
}

/// The request shape a qualified placement serves to the public, as a parity
/// qualification bounds it: greedy decoding only unless `sampling`, no tool
/// schemas unless `tools`, text only unless `vision`, no video unless `video`
/// (which needs `vision`), and prompt and output allowances.
public struct ClusterRequestEnvelope: Codable, Equatable, Sendable {
    public let sampling: Bool
    public let tools: Bool
    public let vision: Bool
    public let video: Bool
    public let maxPromptTokens: Int
    public let maxOutputTokens: Int

    public init(sampling: Bool, tools: Bool, vision: Bool, video: Bool, maxPromptTokens: Int, maxOutputTokens: Int) {
        self.sampling = sampling; self.tools = tools; self.vision = vision; self.video = video
        self.maxPromptTokens = maxPromptTokens; self.maxOutputTokens = maxOutputTokens
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case sampling, tools, vision, video
        case maxPromptTokens = "max_prompt_tokens"
        case maxOutputTokens = "max_output_tokens"
    }
    static let fields = Set(CodingKeys.allCases.map(\.rawValue))
}
