import Foundation

/// How far a candidate run agrees with a reference run of the same request.
///
/// - `exact`: tokens, frame count, committed frontier and the final row's
///   native bytes are equal, and every state entry both sides recorded.
/// - `tokensEqualLogitsDiffer`: every token is equal; the final row or a state
///   entry is not bit-identical.
/// - `divergedAtNearTie`: the first different token was, in the reference, within
///   the near-tie threshold of the reference's choice.
/// - `diverged`: the first different token was not a near tie, or cannot be
///   shown to be one.
/// - `incomparable`: the runs are not the same request, or the evidence needed
///   to choose between the verdicts above is missing.
public enum QualificationVerdict: String, Codable, CaseIterable, Sendable {
    case exact, tokensEqualLogitsDiffer, divergedAtNearTie, diverged, incomparable
}

public struct QualificationComparison: Codable, Equatable, Sendable {
    public struct Tokens: Codable, Equatable, Sendable {
        public var referenceCount: Int
        public var candidateCount: Int
        public var equalPrefixLength: Int
        public var firstDivergenceIndex: Int?
        public var finishReasons: [String]
        public var equal: Bool { firstDivergenceIndex == nil }
    }
    public struct Logits: Codable, Equatable, Sendable {
        public var bytesEqual: Bool
        public var maximumAbsoluteDifference: Float
        public var indexOfMaximumDifference: Int
        public var differingValueCount: Int
        public var meanAbsoluteDifference: Double
        public var argmaxEqual: Bool
        /// The reference's own margin on this row, for scale.
        public var referenceTop1Top2Margin: Float
    }
    public struct State: Codable, Equatable, Sendable {
        public var entriesCompared: Int
        public var differingEntries: [String]
        public var fingerprintsEqual: Bool?
    }
    public struct Divergence: Codable, Equatable, Sendable {
        public var index: Int
        public var referenceTokenID: Int?
        public var candidateTokenID: Int?
        public var referenceTop1Logit: Float?
        public var referenceTop2TokenID: Int?
        public var referenceTop1Top2Margin: Float?
        /// Reference logit of the reference's choice minus that of the candidate's.
        public var referenceGapToCandidateToken: Float?
        public var candidateTokenReferenceRank: Int?
        public var ulpAtTop1: Float?
        public var gapInULPs: Float?
        public var nearTieThresholdULPs: Float
        public var nearTie: Bool
    }

    public var verdict: QualificationVerdict
    public var reasons: [String]
    public var referenceLabel: String
    public var candidateLabel: String
    public var identityMatches: Bool
    public var identityDifferences: [String]
    public var identityFieldsNotCompared: [String]
    public var tokens: Tokens
    public var completedFramesEqual: Bool?
    public var committedTokensEqual: Bool?
    public var logits: Logits?
    public var logitsNotCompared: String?
    public var state: State?
    public var divergence: Divergence?
}

public struct QualificationComparator: Sendable {
    /// A divergence is a near tie when the reference's gap between its own
    /// choice and the candidate's is at most this many units in the last place
    /// of the reference's top logit, in the row's native precision.
    public var nearTieULPs: Float
    public var allowCutDifference: Bool
    public var allowScheduleDifference: Bool
    /// Profiles that differ only in their limits (the long-context profiles
    /// against a reference recorded under the earlier 8,192-token reservation).
    public var allowProfileDifference: Bool

    public init(nearTieULPs: Float = 4, allowCutDifference: Bool = false, allowScheduleDifference: Bool = false,
                allowProfileDifference: Bool = false) {
        self.nearTieULPs = nearTieULPs; self.allowCutDifference = allowCutDifference
        self.allowScheduleDifference = allowScheduleDifference; self.allowProfileDifference = allowProfileDifference
    }

    /// Spacing of adjacent representable values at `value` for a row dtype.
    public static func unitInLastPlace(of value: Float, dtype: String) -> Float? {
        let fractionBits: Int
        switch dtype {
        case "bfloat16": fractionBits = 7
        case "float16": fractionBits = 10
        case "float32": fractionBits = 23
        default: return nil
        }
        guard value.isFinite, value != 0 else { return nil }
        return Float(sign: .plus, exponent: Int(value.exponent) - fractionBits, significand: 1)
    }

    public func compare(reference: QualificationSubject, candidate: QualificationSubject) throws -> QualificationComparison {
        let identity = reference.identity.differences(from: candidate.identity, allowCutDifference: allowCutDifference,
                                                      allowScheduleDifference: allowScheduleDifference,
                                                      allowProfileDifference: allowProfileDifference)
        let a = reference.evidence, b = candidate.evidence
        let prefix = zip(a.selectedTokenIDs, b.selectedTokenIDs).prefix { $0 == $1 }.count
        let countsEqual = a.selectedTokenIDs.count == b.selectedTokenIDs.count
        let first: Int? = prefix == a.selectedTokenIDs.count && countsEqual ? nil : prefix
        var result = QualificationComparison(verdict: .incomparable, reasons: [],
            referenceLabel: reference.label, candidateLabel: candidate.label,
            identityMatches: identity.differing.isEmpty, identityDifferences: identity.differing,
            identityFieldsNotCompared: identity.notCompared,
            tokens: .init(referenceCount: a.selectedTokenIDs.count, candidateCount: b.selectedTokenIDs.count,
                equalPrefixLength: prefix, firstDivergenceIndex: first, finishReasons: [a.finishReason, b.finishReason]),
            completedFramesEqual: zipOptional(a.completedFrames, b.completedFrames).map { $0 == $1 },
            committedTokensEqual: zipOptional(a.committedTokens, b.committedTokens).map { $0 == $1 })
        if allowCutDifference && reference.identity.stageCut != candidate.identity.stageCut {
            result.reasons.append("stage cuts differ (\(reference.identity.stageCut) and \(candidate.identity.stageCut)) and were allowed to")
        }
        if allowProfileDifference && reference.identity.profileFingerprint != candidate.identity.profileFingerprint {
            result.reasons.append("profile fingerprints differ (limits only: same model, profile, tokens, chunk, outputs and stops) and were allowed to")
        }
        if allowScheduleDifference && reference.identity.prefillSchedule != candidate.identity.prefillSchedule {
            result.reasons.append("prefill schedules differ (\(reference.identity.prefillSchedule) and \(candidate.identity.prefillSchedule)) and were allowed to")
        }
        if let rows = try compareLogits(a, b) { result.logits = rows }
        else {
            result.logitsNotCompared = a.finalLogits == nil
                ? "the reference report has no final row" : "the candidate report has no final row"
        }
        // State is only meaningful at the same committed frontier.
        if first == nil { result.state = compareState(a, b) }

        guard identity.differing.isEmpty else {
            result.reasons.append("the runs are not the same request: " + identity.differing.joined(separator: ", ") + " differ")
            return result
        }
        guard !a.selectedTokenIDs.isEmpty, !b.selectedTokenIDs.isEmpty else {
            result.reasons.append("a report has no selected tokens")
            return result
        }
        if let first {
            let detail = divergence(at: first, reference: a, candidate: b)
            result.divergence = detail
            result.verdict = detail.nearTie ? .divergedAtNearTie : .diverged
            if !countsEqual && prefix == min(a.selectedTokenIDs.count, b.selectedTokenIDs.count) {
                result.reasons.append("token counts differ after an equal prefix of \(prefix)")
            } else if detail.referenceTop1Top2Margin == nil {
                result.reasons.append("the reference has no per-step margin at index \(first), so a near tie cannot be shown")
            } else if detail.referenceGapToCandidateToken == nil {
                result.reasons.append("the candidate's token is not among the reference's recorded top values at index \(first)")
            }
            return result
        }
        if result.completedFramesEqual == false, result.committedTokensEqual != false,
           let framing = prefillFramingExplains(reference: reference, candidate: candidate) {
            // Same request, same tokens, same committed frontier: the frames
            // differ only in how the prompt was framed, which each run's own
            // recorded prefix plan accounts for exactly (the prefix cache runs
            // the last prompt token alone; a restored prefix is not prefilled).
            result.reasons.append(framing)
        } else {
            guard result.completedFramesEqual != false, result.committedTokensEqual != false else {
                result.reasons.append("tokens are equal but the frame count or committed frontier differs")
                return result
            }
        }
        guard let logits = result.logits else {
            // Without a final row, a run whose every selected row carries its
            // native bytes' digest (MiMo's step evidence) is told apart by those:
            // equal digests on every row are an exact run.
            if let rows = Self.stepRowsEqual(a, b) {
                result.verdict = rows.equal ? .exact : .tokensEqualLogitsDiffer
                result.reasons.append("no final row: the digests of all \(rows.compared) selected rows were compared"
                    + (rows.equal ? " and are equal" : "; the first that differs is at index \(rows.firstDifferent ?? 0)"))
                return result
            }
            result.reasons.append("all \(prefix) tokens are equal, but \(result.logitsNotCompared!), so exact and tokensEqualLogitsDiffer cannot be told apart")
            return result
        }
        let stateDiffers = !(result.state?.differingEntries.isEmpty ?? true)
        if logits.bytesEqual && !stateDiffers {
            result.verdict = .exact
            if result.state == nil { result.reasons.append("state entries were not recorded on both sides and were not compared") }
        } else {
            result.verdict = .tokensEqualLogitsDiffer
            if logits.bytesEqual { result.reasons.append("the final row is bit-identical but \(result.state!.differingEntries.count) state entries differ") }
        }
        return result
    }

    /// A note when each run's frame count is exactly its own prefill framing
    /// (its recorded prefix plan, or fixed chunks from zero without one) plus
    /// one decode frame per token after the first, and the two framings
    /// differ; nil otherwise.
    func prefillFramingExplains(reference: QualificationSubject, candidate: QualificationSubject) -> String? {
        let prompt = reference.identity.promptTokenCount, chunk = reference.identity.chunkSize
        guard prompt == candidate.identity.promptTokenCount, chunk == candidate.identity.chunkSize,
              reference.evidence.selectedTokenIDs.count == candidate.evidence.selectedTokenIDs.count,
              !reference.evidence.selectedTokenIDs.isEmpty else { return nil }
        let decodeFrames = reference.evidence.selectedTokenIDs.count - 1
        func framing(_ subject: QualificationSubject) -> (frames: Int, label: String)? {
            let plan = subject.evidence.prefillPlan ?? .init(reusedPromptTokens: 0, splitFinalPromptToken: false)
            guard let prefill = plan.prefillFrames(prompt: prompt, chunk: chunk),
                  subject.evidence.completedFrames == prefill + decodeFrames else { return nil }
            let label = subject.evidence.prefillPlan == nil ? "fixed chunks" : (plan.splitFinalPromptToken
                ? "prefix cache: \(plan.reusedPromptTokens) reused, last prompt token alone" : "prefix cache: \(plan.reusedPromptTokens) reused")
            return (prefill, label)
        }
        guard let a = framing(reference), let b = framing(candidate), a.frames != b.frames else { return nil }
        return "the prompt was framed differently (reference \(a.frames) prefill frames, \(a.label); candidate "
            + "\(b.frames), \(b.label)); tokens and the committed frontier are equal, so the frame counts are compared "
            + "through each run's own framing"
    }

    /// Row digests both runs recorded for every selected token, compared on
    /// the characters both carry (at least 16: a runtime line keeps 64 bits).
    /// Nil unless each side has exactly one step per selected token, in order.
    static func stepRowsEqual(_ a: QualificationEvidence, _ b: QualificationEvidence)
        -> (equal: Bool, compared: Int, firstDifferent: Int?)? {
        guard let x = a.steps, let y = b.steps, !a.selectedTokenIDs.isEmpty,
              a.selectedTokenIDs == b.selectedTokenIDs else { return nil }
        let count = a.selectedTokenIDs.count
        guard x.map(\.ordinal) == Array(0..<count), y.map(\.ordinal) == Array(0..<count) else { return nil }
        var first: Int?
        for index in 0..<count {
            let left = x[index].rowSHA256.lowercased(), right = y[index].rowSHA256.lowercased()
            let shared = min(left.count, right.count)
            guard shared >= 16, left.allSatisfy(\.isHexDigit), right.allSatisfy(\.isHexDigit) else { return nil }
            if first == nil, left.prefix(shared) != right.prefix(shared) { first = index }
        }
        return (first == nil, count, first)
    }

    private func zipOptional<T>(_ a: T?, _ b: T?) -> (T, T)? {
        guard let a, let b else { return nil }
        return (a, b)
    }

    private func compareLogits(_ a: QualificationEvidence, _ b: QualificationEvidence) throws -> QualificationComparison.Logits? {
        guard let x = a.finalLogits, let y = b.finalLogits else { return nil }
        let left = try x.values(), right = try y.values()
        guard left.count == right.count, !left.isEmpty, x.shape == y.shape else {
            throw QualificationError("Final rows have different shapes")
        }
        var maximum: Float = 0, index = 0, differing = 0
        var total = 0.0
        for position in left.indices {
            let delta = abs(left[position] - right[position])
            if left[position].bitPattern != right[position].bitPattern { differing += 1 }
            if delta > maximum { maximum = delta; index = position }
            total += Double(delta)
        }
        func top(_ values: [Float]) -> (index: Int, margin: Float) {
            var best = 0, second = -1
            for position in values.indices.dropFirst() {
                if values[position] > values[best] { second = best; best = position }
                else if second < 0 || values[position] > values[second] { second = position }
            }
            return (best, second < 0 ? 0 : values[best] - values[second])
        }
        let reference = top(left)
        return .init(bytesEqual: x.dtype == y.dtype && x.byteCount == y.byteCount
                && x.logicalBytesSHA256 == y.logicalBytesSHA256 && differing == 0,
            maximumAbsoluteDifference: maximum, indexOfMaximumDifference: index, differingValueCount: differing,
            meanAbsoluteDifference: total / Double(left.count), argmaxEqual: reference.index == top(right).index,
            referenceTop1Top2Margin: reference.margin)
    }

    private func compareState(_ a: QualificationEvidence, _ b: QualificationEvidence) -> QualificationComparison.State? {
        guard let x = a.stateEntries, let y = b.stateEntries else { return nil }
        let right = Dictionary(y.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var differing = x.filter { right[$0.key] != $0 }.map(\.key)
        differing += y.map(\.key).filter { key in !x.contains { $0.key == key } }
        return .init(entriesCompared: max(x.count, y.count), differingEntries: differing,
            fingerprintsEqual: zipOptional(a.stateSHA256, b.stateSHA256).map { $0 == $1 })
    }

    private func divergence(at index: Int, reference: QualificationEvidence,
                            candidate: QualificationEvidence) -> QualificationComparison.Divergence {
        var detail = QualificationComparison.Divergence(index: index,
            referenceTokenID: reference.selectedTokenIDs.indices.contains(index) ? reference.selectedTokenIDs[index] : nil,
            candidateTokenID: candidate.selectedTokenIDs.indices.contains(index) ? candidate.selectedTokenIDs[index] : nil,
            nearTieThresholdULPs: nearTieULPs, nearTie: false)
        // Both runs consumed the same history up to `index`, so the reference's
        // row there describes the decision the candidate also faced.
        guard let step = reference.steps?.first(where: { $0.ordinal == index }),
              step.topTokenIDs.count == step.topLogits.count, step.topLogits.count >= 2 else { return detail }
        detail.referenceTop1Logit = step.topLogits[0]
        detail.referenceTop2TokenID = step.topTokenIDs[1]
        detail.referenceTop1Top2Margin = step.topLogits[0] - step.topLogits[1]
        let dtype = step.rowDType ?? reference.finalLogits?.dtype ?? "bfloat16"
        detail.ulpAtTop1 = Self.unitInLastPlace(of: step.topLogits[0], dtype: dtype)
        guard let token = detail.candidateTokenID, let rank = step.topTokenIDs.firstIndex(of: token) else { return detail }
        let gap = step.topLogits[0] - step.topLogits[rank]
        detail.candidateTokenReferenceRank = rank + 1
        detail.referenceGapToCandidateToken = gap
        if let ulp = detail.ulpAtTop1 {
            detail.gapInULPs = gap / ulp
            detail.nearTie = gap <= nearTieULPs * ulp
        }
        return detail
    }

    public static func render(_ value: QualificationComparison) -> String {
        var lines = ["reference: \(value.referenceLabel)", "candidate: \(value.candidateLabel)"]
        lines.append("request identity: " + (value.identityMatches ? "matches" : "DIFFERS in " + value.identityDifferences.joined(separator: ", ")))
        if !value.identityFieldsNotCompared.isEmpty {
            lines.append("  not compared (present on one side only): " + value.identityFieldsNotCompared.joined(separator: ", "))
        }
        let tokens = value.tokens
        lines.append("tokens: reference \(tokens.referenceCount), candidate \(tokens.candidateCount), "
            + (tokens.firstDivergenceIndex.map { "first divergence at index \($0)" } ?? "all equal")
            + "; finish \(tokens.finishReasons[0])/\(tokens.finishReasons[1])")
        if let frames = value.completedFramesEqual, let frontier = value.committedTokensEqual {
            lines.append("frames: \(frames ? "equal" : "DIFFER"); committed frontier: \(frontier ? "equal" : "DIFFERS")")
        }
        if let logits = value.logits {
            lines.append("final row: " + (logits.bytesEqual ? "bit-identical"
                : "max |difference| \(logits.maximumAbsoluteDifference) at token \(logits.indexOfMaximumDifference), "
                + "\(logits.differingValueCount) values differ, mean |difference| \(logits.meanAbsoluteDifference), "
                + "argmax \(logits.argmaxEqual ? "equal" : "DIFFERS")")
                + "; reference top-1/top-2 margin \(logits.referenceTop1Top2Margin)")
        } else if let reason = value.logitsNotCompared {
            lines.append("final row: not compared, \(reason)")
        }
        if let state = value.state {
            lines.append("state: \(state.entriesCompared) entries, "
                + (state.differingEntries.isEmpty ? "all digests equal"
                    : "\(state.differingEntries.count) differ (first: \(state.differingEntries.prefix(4).joined(separator: ", ")))"))
        }
        if let detail = value.divergence {
            func text<T>(_ item: T?) -> String { item.map { "\($0)" } ?? "unknown" }
            lines.append("divergence at index \(detail.index): reference chose \(text(detail.referenceTokenID)), candidate chose \(text(detail.candidateTokenID))")
            lines.append("  reference top-1 logit \(text(detail.referenceTop1Logit)), runner-up token \(text(detail.referenceTop2TokenID)), top-1/top-2 margin \(text(detail.referenceTop1Top2Margin))")
            lines.append("  candidate's token in the reference: rank \(text(detail.candidateTokenReferenceRank)), gap \(text(detail.referenceGapToCandidateToken)) = \(text(detail.gapInULPs)) ulp; near-tie threshold \(detail.nearTieThresholdULPs) ulp")
        }
        for reason in value.reasons { lines.append("note: " + reason) }
        lines.append("verdict: \(value.verdict.rawValue)")
        return lines.joined(separator: "\n")
    }
}
