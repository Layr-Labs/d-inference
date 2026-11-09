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
    /// The resident assistant the owner declared public for this artifact's
    /// tensor-parallel placement; nil keeps a setup saved for coordinator
    /// pairing without one.
    public var tensorAssistant: ClusterPublicTensorAssistant? = nil

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

/// A resident assistant the owner declared public for one model's tensor
/// parallel placement: the exact policy a coordinator-paired setup must save
/// (depth, the inline head's inventory, verification) and the evidence
/// document it rests on, whose SHA-256 is `evidenceSHA256` (a test holds them
/// equal). The evidence and `qualifiedAt` are those of the model's
/// tensor-parallel parity qualifications in a release's facts
/// (`ClusterRuntimeApprovalFacts.parityQualifications`), so the qualification
/// a coordinator derives names the speculative decoding it covers.
public struct ClusterPublicTensorAssistant: Sendable, Equatable {
    public let policy: ClusterQwenTensorAssistantPolicy
    public let evidenceDocument: String
    public let evidenceSHA256: String
    /// RFC 3339: when the evidence was recorded.
    public let qualifiedAt: String

    public init(policy: ClusterQwenTensorAssistantPolicy, evidenceDocument: String, evidenceSHA256: String,
                qualifiedAt: String) throws {
        try policy.validate()
        guard ClusterConfigurationSyntax.hash(evidenceSHA256), evidenceDocument.hasPrefix("docs/reports/"),
              evidenceDocument.hasSuffix(".md"), ClusterPairApproval.unixNanoseconds(rfc3339: qualifiedAt) != nil else {
            throw ClusterConfigurationError.invalid("A public tensor assistant names its evidence report, its digest and when it was qualified")
        }
        self.policy = policy; self.evidenceDocument = evidenceDocument; self.evidenceSHA256 = evidenceSHA256
        self.qualifiedAt = qualifiedAt
    }

    /// What the declaration adds to the resource policy a native start and a
    /// release's facts carry (`DistributedInstalledNativeStart.resourcePolicySHA256`):
    /// the arguments both workers are launched with.
    var resourcePolicyFields: [String] {
        [ClusterQwenTensorAssistantPolicy.schemaName, "depth=\(policy.depth)",
         "\(ClusterQwenTensorAssistantPolicy.inventoryArgument)=\(policy.inventorySHA256)",
         "verification=\(policy.verification.rawValue)", "evidence=\(evidenceSHA256)"]
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
    /// The coordinator's bound on an envelope's prompt and output allowances.
    public static let maximumTokens = 1_048_576

    /// Two Apple M5 Ultras (Metal `applegpu_g17d`, NAX on) on macOS 27.0: where the declared evidence ran. It names the
    /// evidence, not a limit: a coordinator applies each declared family's qualification on any Apple silicon pair and
    /// cut (owner, 2026-11-03: "universal for hardware not hardwired to 2x m5 ultras").
    static let twoM5Ultras = ClusterPublicModel.Ranks(count: 2, gpuArchitecture: "applegpu_g17d", macOSMajor: 27, macOSMinor: 0)

    /// Qwen3.8-27B's resident assistant on tensor-parallel pairs (owner, 2026-11-05: "spec decode should be on and
    /// working for all"): the policy local clusters plan by themselves (depth 3, admitted cohorts) with the inline
    /// head's inventory the native metadata helper returns for the registered artifact. Its evidence: same-request
    /// speculative and plain decodes on one pair were identical (`qwen27AssistantEvidenceDocument`).
    static let qwen27AssistantEvidenceDocument = "docs/reports/2026-11-05-qwen27-public-assistant.md"
    static let qwen27TensorAssistant = try! ClusterPublicTensorAssistant(
        policy: try! ClusterQwenTensorAssistantPolicy(depth: 3,
            inventorySHA256: "6bf428caf645e41cfda642108fc9a21d199ca999e80907be7476e87026afb014", verification: .admittedCohort),
        evidenceDocument: qwen27AssistantEvidenceDocument,
        evidenceSHA256: "31b3e3fe147ad9b68d66e4bec02287d752b5cbfd9d0b5e77fb792e822b424ade",
        qualifiedAt: "2026-11-05T17:00:00Z")

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
              families: [.pipeline, .tensorParallel], schedules: [1, 2], ranks: twoM5Ultras,
              tensorAssistant: qwen27TensorAssistant),
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
    /// sampling and tools, prompts and outputs up to the limits the cluster
    /// enforces in that placement's mode (`profile`: what the mode serves of
    /// the worker's runtime profile; a longer prompt or a larger `max_tokens`
    /// is refused), so the coordinator sends a larger public request to a
    /// single Mac instead of to a refusal; and, when the placement serves media
    /// at all (`servesMedia`: both declared models' tensor-parallel paths take
    /// media as the single-Mac product does, `ClusterGLMMedia` and
    /// `ClusterQwenMedia`; a pipeline is text only), media as the model's
    /// catalog entry in the release's environment lists it (`image` for vision,
    /// `video` as well for video).
    public static func requestEnvelope(inputModalities: [String], servesMedia: Bool,
                                       profile: ClusterWorkerProfile) -> ClusterRequestEnvelope {
        let vision = servesMedia && inputModalities.contains("image")
        return .init(sampling: true, tools: true, vision: vision, video: vision && inputModalities.contains("video"),
                     maxPromptTokens: min(profile.maximumPromptTokens, maximumTokens),
                     maxOutputTokens: min(profile.maximumOutputTokens, maximumTokens))
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

    /// A test's own declaration (nil: `declared`). Never set by a product
    /// path: a build's public models and assistants change only with
    /// `declared` and their evidence reports.
    @TaskLocal static var declarationOverride: [ClusterPublicModel]?
    /// `declared`, or a test's own declaration.
    public static var current: [ClusterPublicModel] { declarationOverride ?? declared }

    /// The resident assistant `models` declare public for a runtime model's
    /// installed artifact (mapped as grants map it), with tensor parallel
    /// among its declared families; nil for any other model, artifact or a
    /// model declared without one.
    static func tensorAssistant(runtimeModelID: String, artifactSHA256: String,
                                in models: [ClusterPublicModel] = current) -> ClusterPublicTensorAssistant? {
        guard let model = models.first(where: { $0.runtimeModelID == runtimeModelID }),
              model.families.contains(.tensorParallel),
              ClusterPairServingGrants.qualifyingArtifact(for: artifactSHA256, runtimeModelID: runtimeModelID)
                == model.artifactSHA256 else { return nil }
        return model.tensorAssistant
    }

    /// `tensorAssistant` of a capability record's model and artifact.
    static func tensorAssistant(for capability: ClusterRuntimeCapability) -> ClusterPublicTensorAssistant? {
        tensorAssistant(runtimeModelID: capability.runtimeModelID, artifactSHA256: capability.artifactSHA256)
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
