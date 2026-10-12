import Foundation

/// One cross-cable qualification run, as the qualification runner writes it
/// (`darkbloom-cluster-pair-check record`): the model the pair ran, each
/// rank's chip in rank order, the cuts, the generation mode, and the
/// comparator's verdict against every single-Mac reference it was given.
///
/// This is the only per-model data a pair-serving grant rests on (owner
/// decisions D4 and "universal mechanisms"): a provider derives which chip
/// classes may run each role of a model from the records it carries, never
/// from a hand-written table. A record names no machine, user, address or
/// path: chips and operating system versions only.
///
/// A record passes the owner's near-tie rule when it has at least one
/// comparison and every comparison is `exact`, `tokensEqualLogitsDiffer` or
/// `divergedAtNearTie`. `diverged` and `incomparable` fail it. The runner
/// writes `passed` from that rule; a reader re-derives it and ignores a record
/// whose stored value disagrees (`isConsistent`).
public struct ClusterPairQualificationRecord: Codable, Equatable, Sendable {
    public static let schemaName = "darkbloom_cluster_pair_qualification_v1"
    /// The comparator verdicts a cross-cable check may have and pass.
    public static let acceptedVerdicts: [String] = ["exact", "tokensEqualLogitsDiffer", "divergedAtNearTie"]
    /// The transport of a run on two Macs. A run of both ranks on one Mac over
    /// a loopback socket checks correctness only and qualifies nothing.
    public static let crossCableTransport = "jaccl"
    public static let maximumBytes = 64 * 1024

    public struct Rank: Codable, Equatable, Sendable {
        public let rank: Int
        /// The chip as the Mac that ran the rank names it ("Apple M3 Ultra").
        public let chip: String
        public let operatingSystem: String?

        public init(rank: Int, chip: String, operatingSystem: String?) {
            self.rank = rank; self.chip = chip; self.operatingSystem = operatingSystem
        }
    }

    /// The comparator's result against one single-Mac reference.
    public struct Comparison: Codable, Equatable, Sendable {
        /// The chip of the Mac that recorded the reference.
        public let referenceChip: String?
        public let verdict: String
        public let firstDivergenceIndex: Int?
        public let gapInULPs: Float?
        public let nearTieThresholdULPs: Float
        /// Identity differences the comparison was told to allow (`cut`,
        /// `schedule`, `profile`): a single-Mac reference holds both stages, so
        /// its own cut is bookkeeping.
        public let allowed: [String]

        public init(referenceChip: String?, verdict: String, firstDivergenceIndex: Int?, gapInULPs: Float?,
                    nearTieThresholdULPs: Float, allowed: [String]) {
            self.referenceChip = referenceChip; self.verdict = verdict; self.firstDivergenceIndex = firstDivergenceIndex
            self.gapInULPs = gapInULPs; self.nearTieThresholdULPs = nearTieThresholdULPs; self.allowed = allowed
        }

        public var passes: Bool { ClusterPairQualificationRecord.acceptedVerdicts.contains(verdict) }
    }

    public let schema: String
    /// The runtime's own model identity (the worker's registered model), which
    /// a setup cannot rename.
    public let runtimeModelID: String
    public let artifactSHA256: String
    public let ranks: [Rank]
    /// Layer cuts in rank order, one fewer than the ranks.
    public let cuts: [Int]
    /// `ClusterGenerationMode` raw value.
    public let generationMode: String
    public let prefillSchedule: String
    public let promptTokens: Int
    public let outputTokens: Int
    public let transport: String
    /// The digest of the pair report the record was made from, and when that
    /// run was recorded.
    public let pairReportSHA256: String
    public let pairReportCreatedUTC: String
    public let comparisons: [Comparison]
    public let passed: Bool
    /// Which tool wrote it.
    public let producer: String

    public init(runtimeModelID: String, artifactSHA256: String, ranks: [Rank], cuts: [Int], generationMode: String,
                prefillSchedule: String, promptTokens: Int, outputTokens: Int, transport: String,
                pairReportSHA256: String, pairReportCreatedUTC: String, comparisons: [Comparison], producer: String) {
        schema = Self.schemaName
        self.runtimeModelID = runtimeModelID; self.artifactSHA256 = artifactSHA256; self.ranks = ranks; self.cuts = cuts
        self.generationMode = generationMode; self.prefillSchedule = prefillSchedule
        self.promptTokens = promptTokens; self.outputTokens = outputTokens; self.transport = transport
        self.pairReportSHA256 = pairReportSHA256; self.pairReportCreatedUTC = pairReportCreatedUTC
        self.comparisons = comparisons
        passed = !comparisons.isEmpty && comparisons.allSatisfy(\.passes)
        self.producer = producer
    }

    /// The near-tie rule applied to the comparisons, whatever `passed` says.
    public var passesNearTieRule: Bool { !comparisons.isEmpty && comparisons.allSatisfy(\.passes) }

    public var mode: ClusterGenerationMode? { ClusterGenerationMode(rawValue: generationMode) }

    /// Whether the record is one a grant may rest on, pass or fail: the schema,
    /// two or more ranks in order on two Macs' transport, one cut fewer than
    /// the ranks (positive, ascending), a known mode, and `passed` equal to
    /// the rule.
    public var isConsistent: Bool {
        schema == Self.schemaName && !runtimeModelID.isEmpty && ranks.count >= 2
            && ranks.map(\.rank) == Array(0..<ranks.count) && ranks.allSatisfy { !$0.chip.isEmpty }
            && cuts.count == ranks.count - 1 && cuts.allSatisfy { $0 > 0 } && zip(cuts, cuts.dropFirst()).allSatisfy { $0 < $1 }
            && mode != nil && transport == Self.crossCableTransport && passed == passesNearTieRule
            && comparisons.allSatisfy { $0.nearTieThresholdULPs >= 0 && $0.nearTieThresholdULPs.isFinite }
    }

    /// The first comparison that fails the rule, for a refusal's words.
    public var firstFailure: Comparison? { comparisons.first { !$0.passes } }

    /// One record per line (JSON Lines), as the runner's files concatenate.
    /// Blank lines are skipped; any other line must decode.
    public static func decodeLines(_ text: String) throws -> [Self] {
        let decoder = JSONDecoder()
        return try text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            guard trimmed.utf8.count <= maximumBytes else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "qualification record over \(maximumBytes) bytes"))
            }
            return try decoder.decode(Self.self, from: Data(trimmed.utf8))
        }
    }

    /// One line of JSON with sorted keys, as the runner writes it.
    public func encodedLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
