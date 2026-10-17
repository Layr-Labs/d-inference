import Foundation

/// How the two ranks divide one request. Declared to both ranks when they are
/// launched; never inferred from a request. Support must be advertised by the
/// installed adapter for the registered model and is admitted natively: both
/// ranks bind the mode into their load agreement before either stage is read.
///
/// `pipeline`: every frame passes through rank 0 and then rank 1.
/// `pipelineCompactDecode`: the same pipeline; each decode step's messages
/// travel as four transfers instead of eleven.
/// `phaseSplit`: the prompt is prefilled as a pipeline; after the first
/// selected token rank 0 hands its request state to rank 1, which holds every
/// layer and decodes alone.
/// `phaseSplitMTP`: the same phase split; rank 1 also holds the model's
/// speculative (multi-token prediction) head and decodes with the product's
/// drafter and verifier. Only a model whose artifact ships a head lists it.
/// `tensorParallel`: every rank holds an equal share of every layer (heads and
/// channels, `ClusterTensorParallelTerms`); prefill and decode run on both at
/// once and the partial outputs of each row-parallel projection are summed
/// across the ranks. No layer range is cut.
/// `pipelinePrefillTensorDecode`: the prompt is prefilled as a pipeline at a
/// layer cut; after the first selected token each rank hands the other the
/// request state of the heads it does not own, and both decode by tensor
/// parallel.
///
/// The tensor-parallel modes are listed by a runtime only when it executes
/// them; a placement planner predicts them from the model layout's
/// tensor-parallel facts and chooses one only where it is predicted faster.
/// `pipelineMTP`: the pipeline, with decode as speculative rounds: the last
/// rank also holds the model's head (and a copy of its token embedding),
/// drafts, and both ranks verify the window of drafts in one forward each.
/// Only a model whose artifact ships a head the last rank can run lists it.
public enum ClusterGenerationMode: String, Codable, CaseIterable, Sendable {
    case pipeline = "pipeline_v1"
    case pipelineCompactDecode = "pipeline_compact_decode_v1"
    case phaseSplit = "phase_split_v1"
    case phaseSplitMTP = "phase_split_mtp_v1"
    case tensorParallel = "tensor_parallel_v1"
    case pipelinePrefillTensorDecode = "pipeline_prefill_tensor_decode_v1"
    case pipelineMTP = "pipeline_mtp_v1"

    /// Rank 0 hands its request state to rank 1 after the prompt, and rank 1
    /// holds every layer.
    public var isPhaseSplit: Bool { self == .phaseSplit || self == .phaseSplitMTP }
    /// The last rank drafts with the model's speculative head and the window
    /// is verified by the target (a phase split + MTP, or the pipeline with
    /// speculative rounds).
    public var usesSpeculativeHead: Bool { self == .phaseSplitMTP || self == .pipelineMTP }
    /// Decode runs on every rank at once over equal shards of every layer.
    public var usesTensorParallelDecode: Bool { self == .tensorParallel || self == .pipelinePrefillTensorDecode }
    /// Prefill runs by tensor parallel too: no layer range is cut.
    public var usesTensorParallelPrefill: Bool { self == .tensorParallel }
    /// The request state changes owner after the prompt (a phase split, with
    /// or without the head, or the pipeline-prefill/tensor-decode hybrid).
    /// Kept, but off by default (owner, 2026-10-13: sharded deployments
    /// only): a planner considers these only behind an explicit opt-in.
    public var isHandOff: Bool { isPhaseSplit || self == .pipelinePrefillTensorDecode }
    /// Every member shards the model for every token and no state changes
    /// owner: a pipeline (with or without compact decode framing) or tensor
    /// parallel. What a planner chooses by default.
    public var isSharded: Bool { !isHandOff }
    /// How many layer cuts a placement of `ranks` ranks in this mode has:
    /// none for tensor parallel, one fewer than the ranks for every other mode.
    public func layerCutCount(ranks: Int) -> Int { usesTensorParallelPrefill ? 0 : max(0, ranks - 1) }
    /// The terms both ranks bind for a tensor-parallel mode; nil otherwise.
    public var tensorParallelTerms: ClusterTensorParallelTerms? { usesTensorParallelDecode ? .current : nil }
}

/// What both ranks of a tensor-parallel mode agree on before either reads a
/// weight, bound field by field into the load agreement: a rank started with
/// other terms agrees on nothing.
///
/// - `partialsDType`: each row-parallel projection's partial output is kept
///   in float32 and rounded once, after the sum (decided on hardware
///   2026-10-10: exact against the CPU float32 sum on both chips, about one
///   rounding closer to one Mac than bfloat16 partials).
/// - `shardRule`: contiguous blocks of heads and channels, equal or weighted
///   by the launch's shares in blocks that keep every row-parallel input width
///   on the fast kernel's alignment; every head stays with the key and value
///   heads it reads. The shares themselves are bound beside these terms.
/// - `reduction`: the sealed all-sum inside the lazy graph: each rank's
///   partial leaves as an AES-256-GCM frame under direction keys derived from
///   the session's pinned data-plane exchange (S16) and the load agreement,
///   the frames are all-gathered over RDMA, the peer's is opened (a frame
///   that does not authenticate fails both ranks' evaluation) and the two are
///   added in rank order (two-value IEEE addition is commutative, so both
///   ranks hold the same bits). A native, plaintext all-sum is refused on a
///   keyed data plane.
public struct ClusterTensorParallelTerms: Codable, Equatable, Sendable {
    public var partialsDType: String
    public var shardRule: String
    public var reduction: String
    public var ranks: Int

    public static let current = ClusterTensorParallelTerms(partialsDType: "float32",
        shardRule: "kernel_aligned_heads_and_channels_v1", reduction: "sealed_all_gather_sum_v1", ranks: 2)

    public init(partialsDType: String, shardRule: String, reduction: String, ranks: Int) {
        self.partialsDType = partialsDType; self.shardRule = shardRule; self.reduction = reduction; self.ranks = ranks
    }

    public var loadAgreementFields: [String] {
        ["cluster-tensor-parallel-v1", partialsDType, shardRule, reduction, String(ranks)]
    }
}
