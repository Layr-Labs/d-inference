import DarkbloomClusterProtocol
import Foundation

/// How a family's tensor-parallel plan treats one stored tensor: every rank
/// holds all of it, or each rank holds an equal share (heads, channels or
/// vocabulary rows).
public enum ClusterTensorParallelTensorCut: String, Codable, Sendable {
    case replicated
    case divided
}

/// What a family's tensor-parallel plan is, as the family states it from its
/// own configuration: nil from a family that has no plan (then no
/// tensor-parallel mode is ever predicted or chosen for its models).
public struct ClusterTensorParallelFamilyPlan: Codable, Equatable, Sendable {
    /// The plan's name, for example `qwen_dense_heads_and_channels_v1`.
    public let plan: String
    /// Rank counts the plan divides the model by (equal shards).
    public let ranks: [Int]
    /// Sums of partial outputs per layer per forward (the row-parallel
    /// projections: two for an attention block plus an MLP).
    public let reductionsPerLayer: Int
    /// Reductions per decode step outside the layers (the vocabulary-parallel
    /// head's distributed selection).
    public let reductionsPerStep: Int
    /// Bytes of one rank's partial per token: the residual width times the
    /// partials' element size (`ClusterTensorParallelTerms.partialsDType`).
    public let partialBytesPerToken: Int
    /// True when each rank keeps the request state of its own heads only.
    public let stateDividesByHeads: Bool

    public init(plan: String, ranks: [Int], reductionsPerLayer: Int, reductionsPerStep: Int,
                partialBytesPerToken: Int, stateDividesByHeads: Bool) {
        self.plan = plan; self.ranks = ranks; self.reductionsPerLayer = reductionsPerLayer
        self.reductionsPerStep = reductionsPerStep; self.partialBytesPerToken = partialBytesPerToken
        self.stateDividesByHeads = stateDividesByHeads
    }
}

/// A layout's tensor-parallel facts: the family's plan and, from the
/// artifact's own headers, which loaded bytes each part divides and which it
/// replicates. Derived by `ClusterModelLayoutBuilder`; nothing is typed per
/// model. Nil in a layout whose family has no plan, or written before it.
public struct ClusterTensorParallelLayout: Codable, Equatable, Sendable {
    public static let schemaName = "darkbloom_cluster_tensor_parallel_layout_v1"
    public let schema: String
    public let family: ClusterTensorParallelFamilyPlan
    public let terms: ClusterTensorParallelTerms
    public let layerDividedBytes: [Int]
    public let layerReplicatedBytes: [Int]
    public let ingressDividedBytes: Int
    public let ingressReplicatedBytes: Int
    public let egressDividedBytes: Int
    public let egressReplicatedBytes: Int

    public init(family: ClusterTensorParallelFamilyPlan, terms: ClusterTensorParallelTerms = .current,
                layerDividedBytes: [Int], layerReplicatedBytes: [Int], ingressDividedBytes: Int, ingressReplicatedBytes: Int,
                egressDividedBytes: Int, egressReplicatedBytes: Int) {
        schema = Self.schemaName
        self.family = family; self.terms = terms
        self.layerDividedBytes = layerDividedBytes; self.layerReplicatedBytes = layerReplicatedBytes
        self.ingressDividedBytes = ingressDividedBytes; self.ingressReplicatedBytes = ingressReplicatedBytes
        self.egressDividedBytes = egressDividedBytes; self.egressReplicatedBytes = egressReplicatedBytes
    }

    /// Reductions per decode step over `layerCount` layers.
    public func reductionsPerStep(layerCount: Int) -> Int { family.reductionsPerLayer * layerCount + family.reductionsPerStep }

    /// Bytes one rank of `ranks` holds of these parts: the replicated bytes
    /// whole and the divided bytes' equal share, rounded up.
    func shareBytes(divided: Int, replicated: Int, ranks: Int) -> Int { replicated + (divided + ranks - 1) / ranks }

    func validate(layout: ClusterModelLayout) throws {
        let f = family
        guard schema == Self.schemaName, terms == .current, !f.plan.isEmpty, f.plan.utf8.count <= 96,
              !f.ranks.isEmpty, f.ranks.allSatisfy({ (2...8).contains($0) }), f.ranks == Array(Set(f.ranks)).sorted(),
              f.reductionsPerLayer >= 1, f.reductionsPerLayer <= 16, (0...16).contains(f.reductionsPerStep),
              f.partialBytesPerToken > 0, f.partialBytesPerToken <= 1 << 24,
              layerDividedBytes.count == layout.layerCount, layerReplicatedBytes.count == layout.layerCount,
              zip(zip(layerDividedBytes, layerReplicatedBytes), layout.layers).allSatisfy({ pair, layer in
                  pair.0 >= 0 && pair.1 >= 0 && pair.0 + pair.1 == layer.weights.loadedBytes }),
              ingressDividedBytes >= 0, ingressReplicatedBytes >= 0,
              ingressDividedBytes + ingressReplicatedBytes == layout.ingress.loadedBytes,
              egressDividedBytes >= 0, egressReplicatedBytes >= 0,
              egressDividedBytes + egressReplicatedBytes == layout.egress.loadedBytes else {
            throw ClusterPlacementError("Model layout's tensor-parallel facts are malformed")
        }
    }
}

/// The cost of one reduction of two ranks' partials over the link, measured:
/// `fixedSeconds + bytes * secondsPerByte`. `keyed` is true when it was
/// measured as the product reduces (`ClusterTensorParallelTerms.reduction`:
/// an exchange of authenticated, encrypted records on the keyed data plane
/// and a local add). Only a keyed measurement lets the planner choose a
/// tensor-parallel mode; an unkeyed one (a native all-sum) is reported for
/// comparison and never chosen on, since every cable byte is encrypted.
public struct ClusterReductionCost: Codable, Equatable, Sendable {
    public let fixedSeconds: Double
    public let secondsPerByte: Double
    public let keyed: Bool
    public let provenance: String

    public init(fixedSeconds: Double, secondsPerByte: Double, keyed: Bool, provenance: String) {
        self.fixedSeconds = fixedSeconds; self.secondsPerByte = secondsPerByte; self.keyed = keyed; self.provenance = provenance
    }

    public func seconds(bytes: Int) -> Double { fixedSeconds + Double(max(0, bytes)) * secondsPerByte }

    var valid: Bool {
        fixedSeconds.isFinite && fixedSeconds >= 0 && secondsPerByte.isFinite && secondsPerByte >= 0
            && fixedSeconds + secondsPerByte > 0 && provenance.utf8.count <= 1024
    }
}

/// One device's decode on a model, split the only way two measurements allow:
/// a per-token floor that does not shrink with the weights (the GPU's kernel
/// chain, the host's graph) and a part that does (reading the weights). With
/// the whole model's step `t` and an equal half's step `h` (a shard probe, no
/// reduction): floor `2h - t`, weight part `2(t - h)`, and a `1/k` share then
/// steps in `floor + weight part / k`. Without a half measurement nothing
/// says the step shrinks: the floor is the whole step (no gain is assumed).
public struct ClusterDecodeSplit: Codable, Equatable, Sendable {
    public let wholeStepSeconds: Double
    public let floorSeconds: Double
    public let weightSeconds: Double
    /// True when a shard probe measured the half.
    public let measured: Bool

    public init(rates: ClusterSpeedRates) {
        let whole = 1 / rates.decodeTokensPerSecond
        wholeStepSeconds = whole
        if let shard = rates.tensorShardDecodeTokensPerSecond {
            // A half cannot be faster than half the whole, nor slower than it.
            let half = min(whole, max(whole / 2, 1 / shard))
            floorSeconds = 2 * half - whole; weightSeconds = 2 * (whole - half); measured = true
        } else {
            floorSeconds = whole; weightSeconds = 0; measured = false
        }
    }

    public func shareStepSeconds(ranks: Int) -> Double { floorSeconds + weightSeconds / Double(max(1, ranks)) }
}

/// What the planner predicted for tensor parallel on this model and these
/// devices, whether or not it chose it, and why. Present in a result whenever
/// the layout has tensor-parallel facts.
public struct ClusterTensorParallelAssessment: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        /// A tensor-parallel mode is the chosen placement.
        case chosen
        /// Predicted slower than the chosen placement (or within the margin).
        case predictedSlower
        /// Predicted faster, but this runtime does not execute the mode yet.
        case notExecutedByRuntime
        /// Predicted faster, but no passed qualification covers its shape.
        case notQualified
        /// No placement in this mode fits.
        case doesNotFit
        /// The reduction over the link was not measured on the keyed data
        /// plane, so nothing can be predicted that the product would run.
        case reductionNotMeasured
    }

    public struct Device: Codable, Equatable, Sendable {
        public let device: String
        public let split: ClusterDecodeSplit
    }

    public let verdict: Verdict
    public let reason: String
    /// The fastest predicted placement in each tensor-parallel mode.
    public let tensorParallel: ClusterPlacementCandidate?
    public let hybrid: ClusterPlacementCandidate?
    /// The fastest predicted placement in any other mode, and each Mac alone.
    public let bestOtherSeconds: Double?
    public let bestAloneSeconds: Double?
    public let devices: [Device]
    /// Reductions per decode step, and the predicted seconds they take.
    public let reductionsPerStep: Int
    public let reductionSecondsPerStep: Double?
    public let reductionKeyed: Bool?
}
