import CryptoKit
import DarkbloomClusterProtocol
import Foundation

/// The qualification record of one cross-cable tensor-parallel run
/// (`darkbloom-cluster-tp-check record`): the two ranks' reports compared
/// with each single-Mac reference by the near-tie rule, written as the same
/// `ClusterPairQualificationRecord` a pipeline run's record is, so a
/// pair-serving grant can rest on it. Mode `tensor_parallel_v1`, no cut, and
/// the tensor-parallel layout the run used (`tensorParallelLayout`: plan,
/// partials dtype, shares) bound into the record: a record of one layout
/// qualifies that layout only.
///
/// It refuses what cannot qualify: a rank report that did not pass, ranks
/// that disagree, a run on one Mac (local socket), mismatched ranks, a
/// reference that is not a single-Mac `full` report of the same prompt,
/// configuration and chunk, or an unregistered model (the record names the
/// runtime's registered model and artifact, as the product's records do).
public enum QwenTensorParallelQualification {
    public static let producer = "darkbloom-cluster-tp-check record"

    /// The fields of a tp-check report the record reads.
    public struct Report: Decodable, Sendable {
        public struct Run: Decodable, Sendable { public let tokenIDs: [Int] }
        public let schema: String
        public let mode: String
        public let role: String
        public let rank: Int
        public let size: Int
        public let backend: String?
        public let correctnessOnly: Bool
        public let chip: String
        public let modelConfigurationSHA256: String
        public let modelID: String
        public let promptTokens: Int
        public let promptTokenIDsSHA256: String
        public let outputCount: Int
        public let chunkSize: Int
        public let shares: [Int]?
        /// "sealed-bench" (or a product sealed path) when partials crossed sealed; nil: the native all-sum.
        public let reduction: String?
        public let runs: [Run]
        public let topTokenIDs: [[Int]]?
        public let topLogits: [[Float]]?
        public let repeatsIdentical: Bool
        public let ranksAgree: Bool?
        public let passed: Bool
    }

    /// The near-tie rule (D4) over a reference's recorded top logits: tokens
    /// equal, or the first differing token within `nearTieULPs` bfloat16 ULPs
    /// of the reference's top logit at that step.
    public static func compare(reference: Report, candidate: [Int], nearTieULPs: Float)
        -> ClusterPairQualificationRecord.Comparison {
        func comparison(_ verdict: String, _ index: Int?, _ gap: Float?) -> ClusterPairQualificationRecord.Comparison {
            .init(referenceChip: reference.chip, verdict: verdict, firstDivergenceIndex: index, gapInULPs: gap,
                  nearTieThresholdULPs: nearTieULPs, allowed: [])
        }
        guard let left = reference.runs.first?.tokenIDs, !left.isEmpty, left.count == candidate.count else {
            return comparison("incomparable", nil, nil)
        }
        guard let index = zip(left, candidate).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset else {
            // A tensor-parallel rank records no logits: tokens equal is all it can show.
            return comparison("tokensEqualLogitsDiffer", nil, nil)
        }
        guard let ids = reference.topTokenIDs, let logits = reference.topLogits, ids.indices.contains(index),
              logits.indices.contains(index), let position = ids[index].firstIndex(of: candidate[index]),
              logits[index].indices.contains(position), let top = logits[index].first else {
            return comparison("diverged", index, nil)
        }
        let ulp = top.isFinite && top != 0 ? Float(sign: .plus, exponent: top.exponent - 7, significand: 1)
            : Float(sign: .plus, exponent: -133, significand: 1)
        let gap = (top - logits[index][position]) / ulp
        return comparison(gap <= nearTieULPs ? "divergedAtNearTie" : "diverged", index, gap)
    }

    /// `rank0`/`rank1`: the two rank reports; `references`: single-Mac `full`
    /// reports; `configuration`: the artifact's config.json (its registered
    /// identity); `planName`: the family plan the run used.
    public static func record(rank0: Data, rank1: Data, references: [Data], configuration: Data, planName: String,
                              partialsDType: String, nearTieULPs: Float = 4, createdUTC: String) throws
        -> ClusterPairQualificationRecord {
        let decoder = JSONDecoder()
        let ranks = try [rank0, rank1].map { try decoder.decode(Report.self, from: $0) }
        guard !references.isEmpty else { throw ProbeError("A tensor-parallel record needs at least one single-Mac reference") }
        guard ranks.map(\.rank) == [0, 1], ranks.allSatisfy({ $0.size == 2 && $0.mode.hasPrefix("tp") && $0.passed
                  && $0.ranksAgree == true && $0.repeatsIdentical }) else {
            throw ProbeError("The rank reports are not one passed two-rank tensor-parallel run")
        }
        guard ranks.allSatisfy({ $0.backend == ClusterPairQualificationRecord.crossCableTransport && !$0.correctnessOnly }) else {
            throw ProbeError("The run was not across two Macs over JACCL: it qualifies nothing")
        }
        let first = ranks[0], tokens = first.runs.first?.tokenIDs ?? []
        guard !tokens.isEmpty, ranks[1].runs.first?.tokenIDs == tokens,
              ranks.allSatisfy({ !$0.chip.isEmpty && $0.modelConfigurationSHA256 == first.modelConfigurationSHA256
                  && $0.promptTokenIDsSHA256 == first.promptTokenIDsSHA256 && $0.chunkSize == first.chunkSize
                  && $0.outputCount == first.outputCount && $0.shares == first.shares && $0.mode == first.mode
                  && $0.reduction == first.reduction }) else {
            throw ProbeError("The two rank reports are not the same run")
        }
        // The report names bfloat16 partials in its mode ("tp-bf16-partials"); the record must say the same.
        guard first.mode.hasSuffix("-bf16-partials") == (partialsDType == "bfloat16"), ["float32", "bfloat16"].contains(partialsDType) else {
            throw ProbeError("The run's partials dtype is not \(partialsDType)")
        }
        let definition = try QwenResidentModelDefinition(configuration: configuration)
        let configurationSHA = SHA256.hash(data: configuration).map { String(format: "%02x", $0) }.joined()
        guard configurationSHA == first.modelConfigurationSHA256 else {
            throw ProbeError("The run's model configuration is not this artifact's")
        }
        let comparisons = try references.map { data -> ClusterPairQualificationRecord.Comparison in
            let reference = try decoder.decode(Report.self, from: data)
            guard reference.role == "full", reference.size == 1, reference.passed,
                  reference.modelConfigurationSHA256 == first.modelConfigurationSHA256,
                  reference.promptTokenIDsSHA256 == first.promptTokenIDsSHA256, reference.chunkSize == first.chunkSize,
                  reference.outputCount == first.outputCount else {
                throw ProbeError("A reference is not a single-Mac full report of the same request")
            }
            return compare(reference: reference, candidate: tokens, nearTieULPs: nearTieULPs)
        }
        let shares = first.shares.map { $0.map(String.init).joined(separator: ":") } ?? "equal"
        return ClusterPairQualificationRecord(runtimeModelID: definition.specification.model.rawValue,
            artifactSHA256: definition.specification.artifactSHA256,
            ranks: ranks.map { .init(rank: $0.rank, chip: $0.chip, operatingSystem: nil) }, cuts: [],
            generationMode: ClusterGenerationMode.tensorParallel.rawValue,
            prefillSchedule: ClusterPrefillSchedule.serial.rawValue, chunkTokens: first.chunkSize,
            promptTokens: first.promptTokens, outputTokens: first.outputCount,
            transport: ClusterPairQualificationRecord.crossCableTransport,
            pairReportSHA256: SHA256.hash(data: rank0).map { String(format: "%02x", $0) }.joined(),
            pairReportCreatedUTC: createdUTC, comparisons: comparisons, producer: producer,
            tensorParallelLayout: "plan=\(planName);partials=\(partialsDType);shares=\(shares);reduction=\(first.reduction ?? "native")")
    }
}
