import Foundation

/// The part of a recording worker's sidecar this tool reads. The sidecar is the
/// runtime's `qwen_stage_generation_final_diagnostic_v1` record: one rank's
/// selected history and state digests and, on rank 1, the final logits row.
public struct PairEvidence: Decodable, Equatable, Sendable {
    public static let schema = "qwen_stage_generation_final_diagnostic_v1"
    public static let maximumBytes = 16 * 1024 * 1024

    public struct Execution: Decodable, Equatable, Sendable {
        public let selectedTokenIDs: [Int]
        public let completedFrames: Int
        public let committedTokens: Int
        public let finishReason: String
        public let tokenChainSHA256: String
    }
    public struct Agreement: Decodable, Equatable, Sendable {
        public let requestID: String
        public let sourceConfigurationSHA256: String
        public let artifactAggregateSHA256: String
        public let storageCommitmentSHA256: String
        public let planFingerprint: String
        public let stageFingerprints: [String]
        public let numericalPolicySHA256: String
    }
    public struct Logits: Decodable, Equatable, Sendable {
        public let shape: [Int]
        public let dtype: String
        public let byteCount: Int
        public let logicalBytesSHA256: String
        public let values: [Float]
    }

    public let schema: String
    public let rank: Int
    public let requestFingerprint: String
    public let profileFingerprint: String
    public let execution: Execution
    public let agreement: Agreement
    public let stateEntries: [QualificationStateEntry]
    public let stageStateSHA256: String
    public let finalLogits: Logits?

    public static func decode(_ data: Data, rank: Int) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw QualificationError("Rank \(rank) evidence is empty or exceeds its 16 MiB bound")
        }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw QualificationError("Rank \(rank) evidence is not a final diagnostic record") }
        guard value.schema == schema, value.rank == rank, (value.finalLogits != nil) == (rank == 1),
              QualificationHash.isSHA256(value.requestFingerprint),
              value.finalLogits.map({ $0.values.count == $0.shape.reduce(1, *) && $0.values.allSatisfy(\.isFinite) }) ?? true else {
            throw QualificationError("Rank \(rank) evidence has the wrong schema, rank or final row")
        }
        return value
    }

    /// Joins both ranks' records into one comparable result. Everything the two
    /// ranks both state must agree; state entries must be disjoint.
    public static func join(_ ranks: [Self]) throws -> (evidence: QualificationEvidence, identity: Identity) {
        guard ranks.count == 2, ranks[0].rank == 0, ranks[1].rank == 1, let row = ranks[1].finalLogits else {
            throw QualificationError("Evidence from both ranks is required")
        }
        let a = ranks[0], b = ranks[1]
        guard a.execution == b.execution, a.requestFingerprint == b.requestFingerprint,
              a.profileFingerprint == b.profileFingerprint, a.agreement == b.agreement else {
            throw QualificationError("The two ranks recorded different histories, requests or sources")
        }
        let entries = (a.stateEntries + b.stateEntries)
            .sorted { ($0.globalLayerIndex, $0.component) < ($1.globalLayerIndex, $1.component) }
        guard Set(entries.map(\.key)).count == entries.count else {
            throw QualificationError("The two ranks recorded overlapping state entries")
        }
        let evidence = QualificationEvidence(selectedTokenIDs: a.execution.selectedTokenIDs,
            finishReason: a.execution.finishReason, completedFrames: a.execution.completedFrames,
            committedTokens: a.execution.committedTokens, steps: nil,
            finalLogits: .init(shape: row.shape, dtype: row.dtype, byteCount: row.byteCount,
                               logicalBytesSHA256: row.logicalBytesSHA256, values: row.values),
            stateEntries: entries,
            stateSHA256: QualificationStateEntry.fingerprint(entries, committedTokens: a.execution.committedTokens))
        return (evidence, .init(requestFingerprint: a.requestFingerprint, profileFingerprint: a.profileFingerprint,
            stageSHA256: a.agreement.stageFingerprints, storageCommitmentSHA256: a.agreement.storageCommitmentSHA256,
            arithmeticSHA256: a.agreement.numericalPolicySHA256, planSHA256: a.agreement.planFingerprint,
            artifactSHA256: a.agreement.artifactAggregateSHA256,
            configurationSHA256: a.agreement.sourceConfigurationSHA256, requestID: a.agreement.requestID))
    }

    /// What the native runtime itself bound the run to.
    public struct Identity: Equatable, Sendable {
        public let requestFingerprint: String
        public let profileFingerprint: String
        public let stageSHA256: [String]
        public let storageCommitmentSHA256: String
        public let arithmeticSHA256: String
        public let planSHA256: String
        public let artifactSHA256: String
        public let configurationSHA256: String
        public let requestID: String
    }
}
