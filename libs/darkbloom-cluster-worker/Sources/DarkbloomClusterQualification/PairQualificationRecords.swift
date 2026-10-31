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

    public static func make(pairReport data: Data, references: [Data], comparator: QualificationComparator,
                            timing: (mode: Data, plain: Data)? = nil) throws -> ClusterPairQualificationRecord {
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
        // MiMo has no final row: its pair runs qualify by the decoding rank's
        // step lines instead, one digest and candidate set per selected row
        // (`MiMoQualificationEvidence`). A run with neither is a timing run.
        // Tensor parallel has no recording worker (both ranks compute every
        // token together): its served run is the record, tokens only, with the
        // layout each rank's load line names (`tensorParallelLayout`).
        let declaredMode = pair.generationMode ?? identity.generationMode
        let tensorParallel = declaredMode == ClusterGenerationMode.tensorParallel.rawValue
        var candidateEvidence = evidence
        let layout = tensorParallel ? try tensorParallelLayout(pair) : nil
        if evidence.finalLogits == nil, !tensorParallel {
            guard let steps = try MiMoQualificationEvidence.pairSteps(pair) else {
                throw QualificationError("The pair report has no final row (a timing run, not a qualification run)")
            }
            candidateEvidence.steps = steps
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
        guard let declared = ClusterGenerationMode(rawValue: mode) else { throw QualificationError("Unknown generation mode \(mode)") }
        let candidate = QualificationSubject(label: "two-rank pair", identity: identity, evidence: candidateEvidence)
        var allowed: [String] = []
        if comparator.allowCutDifference { allowed.append("cut") }
        if comparator.allowScheduleDifference { allowed.append("schedule") }
        if comparator.allowProfileDifference { allowed.append("profile") }
        let comparisons = try references.map { referenceData -> ClusterPairQualificationRecord.Comparison in
            if MiMoQualificationEvidence.isReference(referenceData) {
                let (subject, chip, requestBound) = try MiMoQualificationEvidence.reference(referenceData, comparableWith: identity)
                let compared = try comparator.compare(reference: subject, candidate: candidate)
                guard compared.identityMatches else {
                    throw QualificationError("A reference is not the same request as the pair (differs in "
                        + compared.identityDifferences.joined(separator: ", ") + ")")
                }
                return .init(referenceChip: chip, verdict: compared.verdict.rawValue,
                    firstDivergenceIndex: compared.tokens.firstDivergenceIndex, gapInULPs: compared.divergence?.gapInULPs,
                    nearTieThresholdULPs: comparator.nearTieULPs,
                    allowed: allowed + (requestBound ? [] : [MiMoQualificationEvidence.requestByIDAllowance]))
            }
            guard (try? decoder.decode(Header.self, from: referenceData))?.schema == ReferenceReport.currentSchema else {
                throw QualificationError("A reference is not a single-Mac reference report")
            }
            let reference = try decoder.decode(ReferenceReport.self, from: referenceData)
            var compared = try comparator.compare(
                reference: .init(label: "single-host reference", identity: reference.identity, evidence: reference.evidence),
                candidate: candidate)
            // Equal tokens with no final row on the tensor-parallel side: all such a run can show.
            if tensorParallel, compared.verdict == .incomparable, compared.identityMatches, compared.tokens.equal,
               compared.logits == nil, compared.completedFramesEqual != false, compared.committedTokensEqual != false,
               !candidateEvidence.selectedTokenIDs.isEmpty {
                compared.verdict = .tokensEqualLogitsDiffer
            }
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
        let measured = try timing.map { try measuredDecode(mode: $0.mode, plain: $0.plain, recorded: pair, identity: identity,
            declared: declared) }
        return .init(runtimeModelID: identity.modelID, artifactSHA256: identity.artifactSHA256, ranks: recorded,
            // Tensor parallel cuts no layer range; every other mode names its cut.
            cuts: declared.layerCutCount(ranks: recorded.count) == 0 ? [] : [identity.stageCut], generationMode: mode, prefillSchedule: identity.prefillSchedule, chunkTokens: identity.chunkSize,
            promptTokens: identity.promptTokenCount, outputTokens: identity.outputCount, transport: transport,
            pairReportSHA256: QualificationHash.sha256(data), pairReportCreatedUTC: pair.createdUTC,
            comparisons: comparisons, producer: producer, tensorParallelLayout: layout, measuredDecode: measured)
    }

    /// The layout both ranks loaded, from their load lines: the same plan and
    /// shares on each, and the sealed all-sum (the only reduction the product
    /// runs). "equal" names equal shares, as the tp-check record does.
    static func tensorParallelLayout(_ pair: PairReport) throws -> String {
        let ranks = pair.ranks.sorted { $0.rank < $1.rank }
        let loads = try ranks.map { rank -> [String: String] in
            guard let line = rank.runtimeLines?.last(where: { $0.hasPrefix("darkbloom-tensor-parallel-load-v1 ") }) else {
                throw QualificationError("Rank \(rank.rank) of the tensor-parallel pair report has no load line")
            }
            var fields: [String: String] = [:]
            for pair in line.split(separator: " ").dropFirst() {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { fields[parts[0]] = parts[1] }
            }
            guard fields["rank"] == String(rank.rank) else {
                throw QualificationError("Rank \(rank.rank)'s load line names another rank")
            }
            return fields
        }
        guard ranks.count == ClusterTensorParallelTerms.current.ranks, let first = loads.first,
              let plan = first["plan"], !plan.isEmpty, let shares = first["shares"],
              loads.allSatisfy({ $0["plan"] == plan && $0["shares"] == shares }) else {
            throw QualificationError("The ranks of the tensor-parallel pair report did not load one plan and one set of shares")
        }
        guard loads.allSatisfy({ $0["sealed"] == "1" }) else {
            throw QualificationError("A rank's all-sum was not sealed: the product's tensor parallel always seals it")
        }
        let weights = shares.split(separator: "-").compactMap { Int($0) }
        guard weights.count == ranks.count, weights.allSatisfy({ $0 > 0 }) else {
            throw QualificationError("The load line's shares \(shares) are not one weight per rank")
        }
        let terms = ClusterTensorParallelTerms.current
        let named = Set(weights).count == 1 ? "equal" : weights.map(String.init).joined(separator: ":")
        return "plan=\(plan);partials=\(terms.partialsDType);shares=\(named);reduction=\(terms.reduction)"
    }

    /// Decode speeds of two timed runs (`--evidence none`) of the recorded
    /// pair's placement and request: one in its mode, one as the plain
    /// pipeline. Each must have completed across two Macs with its ranks
    /// agreeing, on the same chips in the same order, the same model, artifact,
    /// cut, request (prompt digest, chunk, outputs, stops) and prefill schedule
    /// as the recorded run; the mode run in the record's mode and the plain run
    /// in `pipeline_v1`. A run's figure is the median decode rate of its
    /// requests (a repeated run measures each).
    static func measuredDecode(mode modeData: Data, plain plainData: Data, recorded: PairReport,
                               identity: QualificationIdentity, declared: ClusterGenerationMode) throws
        -> ClusterPairQualificationRecord.MeasuredDecode {
        let decoder = JSONDecoder()
        func timed(_ data: Data, as expected: ClusterGenerationMode, role: String) throws -> Double {
            let report = try decoder.decode(PairReport.self, from: data)
            guard report.schema == PairReport.currentSchema, report.outcome == "completed", !report.recording,
                  report.ranksAgreeOnTokens != false,
                  (report.workerTransport ?? ClusterPairQualificationRecord.crossCableTransport)
                      == ClusterPairQualificationRecord.crossCableTransport else {
                throw QualificationError("The \(role) timing report is not a completed timed run across two Macs")
            }
            guard let other = report.identity, (report.generationMode ?? other.generationMode) == expected.rawValue else {
                throw QualificationError("The \(role) timing report did not run \(expected.rawValue)")
            }
            guard other.modelID == identity.modelID, other.artifactSHA256 == identity.artifactSHA256,
                  other.stageCut == identity.stageCut, other.promptTokenIDsSHA256 == identity.promptTokenIDsSHA256,
                  other.chunkSize == identity.chunkSize, other.outputCount == identity.outputCount,
                  other.stopTokenIDs == identity.stopTokenIDs, other.prefillSchedule == identity.prefillSchedule,
                  report.ranks.sorted(by: { $0.rank < $1.rank }).map(\.chip)
                      == recorded.ranks.sorted(by: { $0.rank < $1.rank }).map(\.chip) else {
                throw QualificationError("The \(role) timing report is not the recorded run's placement and request")
            }
            let rates = (report.timing.repetitions?.compactMap(\.decodeTokensPerSecond)).flatMap { $0.isEmpty ? nil : $0 }
                ?? report.timing.decodeTokensPerSecond.map { [$0] } ?? []
            let sorted = rates.filter { $0.isFinite && $0 > 0 }.sorted()
            guard !sorted.isEmpty, sorted.count == rates.count else {
                throw QualificationError("The \(role) timing report has no decode rate")
            }
            return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        let value = ClusterPairQualificationRecord.MeasuredDecode(
            modeTokensPerSecond: try timed(modeData, as: declared, role: "mode"),
            plainPipelineTokensPerSecond: try timed(plainData, as: .pipeline, role: "plain pipeline"),
            modeReportSHA256: QualificationHash.sha256(modeData), plainReportSHA256: QualificationHash.sha256(plainData))
        guard value.isWellFormed else { throw QualificationError("The timing reports' decode rates are not positive") }
        return value
    }
}
