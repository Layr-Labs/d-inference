import Foundation
import DarkbloomClusterProtocol

/// One model whose clusters serve public traffic (`ClusterPublicModels`): the
/// mode families and schedules the owner declared, and the ranks its evidence
/// ran on.
public struct ClusterPublicModel: Sendable, Equatable {
    /// The runtime's own model identity (the worker's registered model).
    public let runtimeModelID: String
    /// The catalog model ID the owner declared: a release's facts carry the
    /// grant and qualifications under this ID only.
    public let catalogModelID: String
    /// The artifact the runtime registers for the model, which the evidence ran.
    public let artifactSHA256: String
    /// The mode families the owner declared public, in order.
    public let families: [ClusterPairServingModeFamily]
    /// The prefill schedules qualified: 1 serial, 2 one-chunk lookahead.
    public let schedules: [UInt8]
    /// The ranks of the evidence placement.
    public let ranks: Ranks

    /// The evidence placement's ranks: how many, each on one GPU architecture
    /// and macOS version.
    public struct Ranks: Sendable, Equatable {
        public let count: Int
        /// Metal's architecture name of each rank's GPU (`applegpu_g17d`: Apple M5 Ultra).
        public let gpuArchitecture: String
        public let macOSMajor: Int
        public let macOSMinor: Int
    }
}

/// The models whose clusters serve public traffic: the owner's declaration
/// (jonathan308, 2026-10-31: "public traffic should not be manual"; "only glm
/// 5.3 flash should be serving public & qwen 3.8 27b they are both good to go
/// they should be approved for serving"; 2026-11-03: "Mark them all approved
/// for public traffic", then "just add Mimo and Gemma to start": MiMo-V2.6-Flash
/// and Gemma 4 26B QAT), reviewed in PRs like any code. A
/// release's cluster runtime facts carry, for each of these models, a
/// pair-serving grant of the declared families and a parity qualification for
/// each declared family and schedule (`ClusterRuntimeApprovalFacts`), from
/// which a coordinator derives the grant and the parity qualifications of
/// their approvals. Any other model's grant comes from the build's bundled
/// records, and its clusters serve their owner only. The evidence is
/// `evidenceDocument`, whose SHA-256 is `evidenceSHA256` (a test holds them
/// equal), so a released CLI names it without carrying the file.
public enum ClusterPublicModels {
    public static let evidenceDocument = "docs/reports/2026-10-31-public-cluster-models.md"
    public static let evidenceSHA256 = "cb16451549b2ba1f3a1908e280c17f572260c227aa27e86b73d39b8c3e6530a9"
    public static let qualifiedAt = "2026-11-03T00:00:00Z"
    /// A public request's prompt and output allowance: the coordinator's
    /// maximum, so only the model's own limits apply.
    public static let maximumTokens = 1_048_576

    /// Two Apple M5 Ultras (Metal `applegpu_g17d`, NAX on) on macOS 27.0: where the declared evidence ran. It names the
    /// evidence, not a limit: a coordinator applies each declared family's qualification on any Apple silicon pair and
    /// cut (owner, 2026-11-03: "universal for hardware not hardwired to 2x m5 ultras").
    static let twoM5Ultras = ClusterPublicModel.Ranks(count: 2, gpuArchitecture: "applegpu_g17d", macOSMajor: 27, macOSMinor: 0)

    /// Owner ruling, 2026-10-31: "It should be tensor or pipeline obviously but that shouldn't matter for the coordinator".
    /// MiMo-V2.6-Flash and Gemma 4 26B QAT (2026-11-03) take the same two families: their pipeline rests on the bundled
    /// records, their tensor parallel on the owner's decision (its code lands with #1706 and #1707). MiMo also keeps
    /// the speculative pipeline its records grant, its default split: a declared grant replaces the records' families,
    /// and a coordinator never forms a pair planned in a family its grant omits.
    public static let declared: [ClusterPublicModel] = [
        .init(runtimeModelID: "registered_glm53_flash", catalogModelID: "glm-5.3-flash",
              artifactSHA256: "3aae613ff188bb0f72e880774a84e4d8e9943ab20c929d8a302af9c57b97d5ac",
              families: [.pipeline, .tensorParallel], schedules: [1, 2], ranks: twoM5Ultras),
        .init(runtimeModelID: "registered_qwen38_27b", catalogModelID: "EigenLabs/Qwen3.8-27B-4bit-mtp",
              artifactSHA256: "bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463",
              families: [.pipeline, .tensorParallel], schedules: [1, 2], ranks: twoM5Ultras),
        .init(runtimeModelID: "registered_mimo_v26_flash_mopd", catalogModelID: "mimo-v2.6-flash-mopd",
              artifactSHA256: "2334547d8acc9898ad4a74570ce44d2b12390bbac8d4bc52c092eb5ad5cfe034",
              families: [.pipeline, .pipelineSpeculative, .tensorParallel], schedules: [1, 2], ranks: twoM5Ultras),
        .init(runtimeModelID: "registered_gemma4_26b_qat_4bit", catalogModelID: "gemma-4-26b-qat-4bit",
              artifactSHA256: "2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785",
              families: [.pipeline, .tensorParallel], schedules: [1, 2], ranks: twoM5Ultras),
    ]

    /// The placement a declared family is qualified at, for a model of
    /// `layers` layers on `ranks` ranks: tensor parallel splits every layer
    /// (`tensor_parallel_v1`, no cut); a pipeline (`pipeline_v1`) cuts the
    /// layers evenly (two ranks: `[layers / 2]`), so it needs the layer count,
    /// and a speculative pipeline (`pipeline_mtp_v1`, its last rank drafting)
    /// is cut the same way. Nil for a hand-off (an opt-in, never declared), or
    /// a pipeline without enough layers.
    static func placement(of family: ClusterPairServingModeFamily, layers: Int?, ranks: Int)
        -> (mode: ClusterGenerationMode, cuts: [Int])? {
        switch family {
        case .tensorParallel: return (.tensorParallel, [])
        case .pipeline, .pipelineSpeculative:
            guard let layers, ranks >= 2, layers >= ranks else { return nil }
            return (family == .pipeline ? .pipeline : .pipelineMTP, (1..<ranks).map { $0 * layers / ranks })
        case .handOff: return nil
        }
    }

    /// The request shape a placement of a declared model serves publicly:
    /// sampling and tools, prompts and outputs up to the model's own limits,
    /// and, when the placement serves media at all (`servesMedia`: both
    /// declared models' tensor-parallel paths take media as the single-Mac
    /// product does, `ClusterGLMMedia` and `ClusterQwenMedia`; a pipeline is
    /// text only), media as the model's catalog entry in the release's
    /// environment lists it (`image` for vision, `video` as well for video).
    public static func requestEnvelope(inputModalities: [String], servesMedia: Bool) -> ClusterRequestEnvelope {
        let vision = servesMedia && inputModalities.contains("image")
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
