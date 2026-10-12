import DarkbloomClusterProtocol
import Foundation

/// Makes the qualification record of one cross-cable run: the pair report the
/// driver wrote, compared by the comparator with every single-Mac reference
/// given (`darkbloom-cluster-pair-check record`). The record is what a
/// provider's pair-serving grant rests on (`ClusterPairQualificationRecord`).
///
/// It refuses what cannot qualify a pair: a run that did not complete, ranks
/// that disagree on the tokens, both ranks on one Mac (`local-socket-test`), a
/// rank with no chip name, a reference that is a pair report or another
/// request (identity differences beyond the allowances), or no reference at
/// all. A comparison that fails the near-tie rule does not refuse: it is a
/// record too, and it withholds the model.
public enum PairQualificationRecords {
    public static let producer = "darkbloom-cluster-pair-check record"

    public static func make(pairReport data: Data, references: [Data], comparator: QualificationComparator) throws
        -> ClusterPairQualificationRecord {
        guard !references.isEmpty else { throw QualificationError("A qualification record needs at least one single-Mac reference") }
        let decoder = JSONDecoder()
        struct Header: Decodable { let schema: String }
        guard (try? decoder.decode(Header.self, from: data))?.schema == PairReport.currentSchema else {
            throw QualificationError("The candidate is not a pair report")
        }
        let pair = try decoder.decode(PairReport.self, from: data)
        guard pair.outcome == "completed", let identity = pair.identity, let evidence = pair.evidence else {
            throw QualificationError("The pair report records outcome '\(pair.outcome)' and has no evidence to qualify")
        }
        // A recorded run compares rank 0's stream with each rank's history; any
        // run's evidence is joined from both ranks only when their executions
        // are identical (`PairEvidence.join`). Either way a completed report
        // with evidence has ranks that agree, unless it says they do not.
        // A run without `--evidence final-row` (a timed run) cannot tell exact
        // from tokensEqualLogitsDiffer: it measured, it did not qualify.
        guard evidence.finalLogits != nil else {
            throw QualificationError("The pair report has no final row (a timing run, not a qualification run)")
        }
        guard pair.ranksAgreeOnTokens != false else { throw QualificationError("The pair report's ranks do not agree on the tokens") }
        // Reports written before the transport field existed ran over JACCL; the
        // loopback test transport was added with the field.
        let transport = pair.workerTransport ?? ClusterPairQualificationRecord.crossCableTransport
        guard transport == ClusterPairQualificationRecord.crossCableTransport else {
            throw QualificationError("The pair ran over \(transport), not across two Macs: it qualifies nothing")
        }
        let ranks = pair.ranks.sorted { $0.rank < $1.rank }
        guard ranks.count >= 2, ranks.map(\.rank) == Array(0..<ranks.count) else {
            throw QualificationError("The pair report does not list its ranks in order")
        }
        let recorded = try ranks.map { rank -> ClusterPairQualificationRecord.Rank in
            guard let chip = rank.chip, !chip.isEmpty else { throw QualificationError("Rank \(rank.rank) of the pair report names no chip") }
            return .init(rank: rank.rank, chip: chip, operatingSystem: rank.operatingSystem)
        }
        // Reports written before modes existed ran the pipeline.
        let mode = pair.generationMode ?? identity.generationMode ?? ClusterGenerationMode.pipeline.rawValue
        guard ClusterGenerationMode(rawValue: mode) != nil else { throw QualificationError("Unknown generation mode \(mode)") }
        let candidate = QualificationSubject(label: "two-rank pair", identity: identity, evidence: evidence)
        var allowed: [String] = []
        if comparator.allowCutDifference { allowed.append("cut") }
        if comparator.allowScheduleDifference { allowed.append("schedule") }
        if comparator.allowProfileDifference { allowed.append("profile") }
        let comparisons = try references.map { referenceData -> ClusterPairQualificationRecord.Comparison in
            guard (try? decoder.decode(Header.self, from: referenceData))?.schema == ReferenceReport.currentSchema else {
                throw QualificationError("A reference is not a single-Mac reference report")
            }
            let reference = try decoder.decode(ReferenceReport.self, from: referenceData)
            let compared = try comparator.compare(
                reference: .init(label: "single-host reference", identity: reference.identity, evidence: reference.evidence),
                candidate: candidate)
            // A reference of another request, artifact or numerical policy says
            // nothing about this run: it is the operator's mistake, not a verdict.
            guard compared.identityMatches else {
                throw QualificationError("A reference is not the same request as the pair (differs in "
                    + compared.identityDifferences.joined(separator: ", ") + ")")
            }
            return .init(referenceChip: reference.host.chip, verdict: compared.verdict.rawValue,
                firstDivergenceIndex: compared.tokens.firstDivergenceIndex, gapInULPs: compared.divergence?.gapInULPs,
                nearTieThresholdULPs: comparator.nearTieULPs, allowed: allowed)
        }
        return .init(runtimeModelID: identity.modelID, artifactSHA256: identity.artifactSHA256, ranks: recorded,
            cuts: [identity.stageCut], generationMode: mode, prefillSchedule: identity.prefillSchedule,
            promptTokens: identity.promptTokenCount, outputTokens: identity.outputCount, transport: transport,
            pairReportSHA256: QualificationHash.sha256(data), pairReportCreatedUTC: pair.createdUTC,
            comparisons: comparisons, producer: producer)
    }
}
