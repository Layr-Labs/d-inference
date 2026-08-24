import Foundation

/// Exact generated-token agreement between a baseline and candidate report.
///
/// Disagreement is data, not a process failure: approximate prefill candidates
/// are expected to move some tokens. Incompatible model/corpus/sampling inputs
/// throw instead of producing a misleading agreement percentage.
public struct QwenQualityCorpusComparison: Codable, Equatable, Sendable {
    public struct Case: Codable, Equatable, Sendable {
        public let id: String
        public let promptTokenCountMatches: Bool
        public let tokenIDsMatch: Bool
        public let commonPrefixTokenCount: Int
        public let firstMismatchTokenIndex: Int?
        public let baselineGeneratedTokenCount: Int
        public let candidateGeneratedTokenCount: Int
        public let baselineTokenChecksum: String
        public let candidateTokenChecksum: String

        public init(
            id: String,
            promptTokenCountMatches: Bool,
            tokenIDsMatch: Bool,
            commonPrefixTokenCount: Int,
            firstMismatchTokenIndex: Int?,
            baselineGeneratedTokenCount: Int,
            candidateGeneratedTokenCount: Int,
            baselineTokenChecksum: String,
            candidateTokenChecksum: String
        ) {
            self.id = id
            self.promptTokenCountMatches = promptTokenCountMatches
            self.tokenIDsMatch = tokenIDsMatch
            self.commonPrefixTokenCount = commonPrefixTokenCount
            self.firstMismatchTokenIndex = firstMismatchTokenIndex
            self.baselineGeneratedTokenCount = baselineGeneratedTokenCount
            self.candidateGeneratedTokenCount = candidateGeneratedTokenCount
            self.baselineTokenChecksum = baselineTokenChecksum
            self.candidateTokenChecksum = candidateTokenChecksum
        }
    }

    public let baselineLabel: String
    public let candidateLabel: String
    public let comparedCaseCount: Int
    public let exactMatchCaseCount: Int
    public let exactMatchRate: Double
    public let totalComparedTokenPositions: Int
    public let matchingTokenPositions: Int
    public let tokenPositionAgreementRate: Double
    public let cases: [Case]

    public init(
        baselineLabel: String,
        candidateLabel: String,
        comparedCaseCount: Int,
        exactMatchCaseCount: Int,
        exactMatchRate: Double,
        totalComparedTokenPositions: Int,
        matchingTokenPositions: Int,
        tokenPositionAgreementRate: Double,
        cases: [Case]
    ) {
        self.baselineLabel = baselineLabel
        self.candidateLabel = candidateLabel
        self.comparedCaseCount = comparedCaseCount
        self.exactMatchCaseCount = exactMatchCaseCount
        self.exactMatchRate = exactMatchRate
        self.totalComparedTokenPositions = totalComparedTokenPositions
        self.matchingTokenPositions = matchingTokenPositions
        self.tokenPositionAgreementRate = tokenPositionAgreementRate
        self.cases = cases
    }

    public static func compare(
        baseline: QwenQualityCorpusReport,
        candidate: QwenQualityCorpusReport
    ) throws -> QwenQualityCorpusComparison {
        try baseline.validate()
        try candidate.validate()
        try validateCompatibility(baseline: baseline, candidate: candidate)

        var rows: [Case] = []
        rows.reserveCapacity(baseline.cases.count)
        var exactCases = 0
        var totalTokenPositions = 0
        var matchingTokenPositions = 0

        for (baselineCase, candidateCase) in zip(baseline.cases, candidate.cases) {
            let prefix = commonPrefixCount(
                baselineCase.generatedTokenIDs,
                candidateCase.generatedTokenIDs)
            let exact = baselineCase.generatedTokenIDs == candidateCase.generatedTokenIDs
            if exact { exactCases += 1 }

            let compared = min(
                baselineCase.generatedTokenIDs.count,
                candidateCase.generatedTokenIDs.count)
            totalTokenPositions += compared
            matchingTokenPositions += zip(
                baselineCase.generatedTokenIDs.prefix(compared),
                candidateCase.generatedTokenIDs.prefix(compared)
            ).reduce(into: 0) { count, pair in
                if pair.0 == pair.1 { count += 1 }
            }

            rows.append(Case(
                id: baselineCase.id,
                promptTokenCountMatches:
                    baselineCase.promptTokenCount == candidateCase.promptTokenCount,
                tokenIDsMatch: exact,
                commonPrefixTokenCount: prefix,
                firstMismatchTokenIndex: exact ? nil : prefix,
                baselineGeneratedTokenCount: baselineCase.generatedTokenCount,
                candidateGeneratedTokenCount: candidateCase.generatedTokenCount,
                baselineTokenChecksum: baselineCase.tokenChecksum,
                candidateTokenChecksum: candidateCase.tokenChecksum))
        }

        let caseCount = rows.count
        return QwenQualityCorpusComparison(
            baselineLabel: baseline.run.label,
            candidateLabel: candidate.run.label,
            comparedCaseCount: caseCount,
            exactMatchCaseCount: exactCases,
            exactMatchRate: caseCount > 0 ? Double(exactCases) / Double(caseCount) : 0,
            totalComparedTokenPositions: totalTokenPositions,
            matchingTokenPositions: matchingTokenPositions,
            tokenPositionAgreementRate: totalTokenPositions > 0
                ? Double(matchingTokenPositions) / Double(totalTokenPositions)
                : 0,
            cases: rows)
    }

    private static func validateCompatibility(
        baseline: QwenQualityCorpusReport,
        candidate: QwenQualityCorpusReport
    ) throws {
        guard baseline.model.id == candidate.model.id else {
            throw QwenQualityCorpusComparisonError.modelIDMismatch(
                baseline: baseline.model.id, candidate: candidate.model.id)
        }
        guard baseline.model.artifactSHA256 == candidate.model.artifactSHA256 else {
            throw QwenQualityCorpusComparisonError.modelArtifactMismatch
        }
        guard baseline.corpus.sha256 == candidate.corpus.sha256 else {
            throw QwenQualityCorpusComparisonError.corpusMismatch
        }
        guard baseline.generation == candidate.generation else {
            throw QwenQualityCorpusComparisonError.generationPolicyMismatch
        }
        guard baseline.engine.resolvedKVBackend == candidate.engine.resolvedKVBackend else {
            throw QwenQualityCorpusComparisonError.kvBackendMismatch(
                baseline: baseline.engine.resolvedKVBackend,
                candidate: candidate.engine.resolvedKVBackend)
        }
        guard baseline.engine.prefixCacheEnabled == candidate.engine.prefixCacheEnabled else {
            throw QwenQualityCorpusComparisonError.prefixCacheMismatch
        }
        let baselineIDs = baseline.cases.map(\.id)
        let candidateIDs = candidate.cases.map(\.id)
        guard baselineIDs == candidateIDs else {
            throw QwenQualityCorpusComparisonError.caseOrderMismatch
        }
        for (baselineCase, candidateCase) in zip(baseline.cases, candidate.cases) {
            guard baselineCase.prompt == candidateCase.prompt else {
                throw QwenQualityCorpusComparisonError.promptMismatch(baselineCase.id)
            }
            guard baselineCase.promptTokenCount == candidateCase.promptTokenCount else {
                throw QwenQualityCorpusComparisonError.promptTokenCountMismatch(
                    caseID: baselineCase.id,
                    baseline: baselineCase.promptTokenCount,
                    candidate: candidateCase.promptTokenCount)
            }
        }
    }

    private static func commonPrefixCount(_ lhs: [Int], _ rhs: [Int]) -> Int {
        zip(lhs, rhs).prefix { $0.0 == $0.1 }.count
    }
}

public enum QwenQualityCorpusComparisonError:
    Error, Equatable, CustomStringConvertible
{
    case modelIDMismatch(baseline: String, candidate: String)
    case modelArtifactMismatch
    case corpusMismatch
    case generationPolicyMismatch
    case kvBackendMismatch(baseline: String, candidate: String)
    case prefixCacheMismatch
    case caseOrderMismatch
    case promptMismatch(String)
    case promptTokenCountMismatch(caseID: String, baseline: Int, candidate: Int)

    public var description: String {
        switch self {
        case .modelIDMismatch(let baseline, let candidate):
            return "quality reports use different model IDs: '\(baseline)' vs '\(candidate)'"
        case .modelArtifactMismatch:
            return "quality reports use different model artifact SHA-256 digests"
        case .corpusMismatch:
            return "quality reports use different corpus SHA-256 digests"
        case .generationPolicyMismatch:
            return "quality reports use different generation policies"
        case .kvBackendMismatch(let baseline, let candidate):
            return "quality reports resolved different KV backends: "
                + "'\(baseline)' vs '\(candidate)'"
        case .prefixCacheMismatch:
            return "quality reports use different prefix-cache policies"
        case .caseOrderMismatch:
            return "quality reports contain different case IDs or ordering"
        case .promptMismatch(let id):
            return "quality report prompt differs for case '\(id)'"
        case .promptTokenCountMismatch(let id, let baseline, let candidate):
            return "quality report prompt token count differs for '\(id)': "
                + "\(baseline) vs \(candidate)"
        }
    }
}
