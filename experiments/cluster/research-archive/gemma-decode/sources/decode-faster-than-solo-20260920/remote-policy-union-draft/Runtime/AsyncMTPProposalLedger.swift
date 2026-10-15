import Foundation

/// Serialized CPU protocol state, owned by the existing request owner.
/// No model, native work, target commit, packet I/O or lifetime proof is created
/// here. In particular, a resolve result is NOT permission to publish tokens.
struct AsyncMTPProposalLedger {
    struct Failure: Error { let reason: String }
    struct Scope: Equatable {
        let requestID: UUID, membershipEpoch: UUID
        let targetBuildSHA256, assistantBuildSHA256: String
        let targetArtifactSHA256, assistantArtifactSHA256, embeddingIdentitySHA256: String
    }
    struct BranchID: Equatable {
        let scope: Scope
        let ordinal: UInt64
        let snapshotFrontier: Int
        let initialSeedToken: Int
        let snapshotSHA256: String
    }
    struct Grant: Equatable {
        let branch: BranchID
        let firstPosition: Int
        let count: Int
    }
    struct Window: Equatable {
        let branch: BranchID
        let ordinal: UInt64
        let seedPosition: Int, seedToken: Int
        let draftTokens: [Int]
    }
    struct Resolution: Equatable {
        let window: Window
        let acceptedDraftTokens: Int
        let rejectedDraftTokens: Int
        let nextInputFrontier: Int
        let targetConfirmedTokens: [Int]
        var nextSeedToken: Int { targetConfirmedTokens.last! }
    }
    struct Counters: Equatable {
        var generated = 0, offered = 0, accepted = 0
        var committedOutputTokens = 0, reusedProposalsOffered = 0
        var committedWindows = 0, cancelledBranches = 0
        var deliveredWhileTargetWindowOutstanding = 0
        var bonusEpochsStarted = 0, bonusMismatchesContinued = 0
        var bonusBoundRetirements = 0, bonusNoReadyRetirements = 0
        var bonusMaximumWindows = 0, bonusMaximumInputAdvance = 0, bonusMaximumProducedAdvance = 0
    }
    private struct Proposal { let position: Int, token: Int }
    private struct Branch {
        let id: BranchID
        var highestProducedPosition: Int
        var proposals: [Proposal] = []
        var outstanding: Grant?
        var needsBonusBridge = false
        // Starts only at the FIRST admitted mismatch, never on a matching branch.
        // Subsequent mismatches cannot reset or extend this bounded epoch.
        var bonusEpochFrontier: Int?
        var bonusEpochWindows = 0
        var cancelling = false
    }

    let scope: Scope
    let maximumDraftTokens: Int
    let maximumProducerGrantTokens: Int
    let vocabularySize: Int
    let maximumBufferedProposals: Int
    let maximumInputFrontier: Int
    let bonusContinuationPolicy: AsyncMTPBonusContinuationPolicy
    private(set) var inputFrontier: Int
    private(set) var seedToken: Int
    private(set) var counters = Counters()
    private(set) var requestCancelled = false
    private(set) var requestCompleted = false
    var requestStopped: Bool { requestCancelled || requestCompleted }
    private var branch: Branch?
    private var activeWindow: Window?
    private var pendingResolution: Resolution?
    private var nextBranch: UInt64 = 0, nextWindow: UInt64 = 0
    var requiresBranchRetirement: Bool { branch?.cancelling == true }
    var canReseed: Bool { !requestStopped && branch == nil && activeWindow == nil }
    var proposalCredit: Int {
        guard !requestStopped, let branch, !branch.cancelling, branch.outstanding == nil else { return 0 }
        let ceiling = branch.bonusEpochFrontier.map {
            min(maximumInputFrontier, $0 + AsyncMTPBonusContinuationPolicy.maximumPositions)
        } ?? maximumInputFrontier
        return min(maximumProducerGrantTokens, maximumBufferedProposals - branch.proposals.count,
                   ceiling - branch.highestProducedPosition)
    }

    init(scope: Scope, inputFrontier: Int, seedToken: Int,
         maximumDraftTokens: Int, maximumInputFrontier: Int, vocabularySize: Int,
         bonusContinuationPolicy: AsyncMTPBonusContinuationPolicy = .strict,
         maximumProducerGrantTokens: Int? = nil) throws {
        let producerLimit = maximumProducerGrantTokens ?? maximumDraftTokens
        let hashes = [scope.targetBuildSHA256, scope.assistantBuildSHA256,
            scope.targetArtifactSHA256, scope.assistantArtifactSHA256, scope.embeddingIdentitySHA256]
        guard hashes.allSatisfy(Self.isSHA), [2, 4, 8].contains(maximumDraftTokens),
              producerLimit == maximumDraftTokens || (maximumDraftTokens == 2 && producerLimit == 3),
              !bonusContinuationPolicy.enabled || bonusContinuationPolicy.verificationDepth <= maximumDraftTokens,
              (1...32_768).contains(maximumInputFrontier),
              (1...Int(Int32.max)).contains(vocabularySize),
              (1..<maximumInputFrontier).contains(inputFrontier), (0..<vocabularySize).contains(seedToken) else {
            throw Failure(reason: "Invalid exact scope, context, seed or proposal bound")
        }
        self.scope = scope; self.inputFrontier = inputFrontier; self.seedToken = seedToken
        self.maximumDraftTokens = maximumDraftTokens; self.vocabularySize = vocabularySize
        self.maximumProducerGrantTokens = producerLimit
        self.maximumBufferedProposals = 2 * maximumDraftTokens + 1
        self.maximumInputFrontier = maximumInputFrontier
        self.bonusContinuationPolicy = bonusContinuationPolicy
    }

    /// The existing owner supplies an actually fenced capture at this frontier.
    /// The new branch is intentionally allowed to keep that snapshot while its
    /// own hidden chain advances; it never claims a refreshed target hidden.
    mutating func startBranch(snapshotFrontier: Int, snapshotSHA256: String) throws -> BranchID {
        guard canReseed, snapshotFrontier == inputFrontier, Self.isSHA(snapshotSHA256), nextBranch < UInt64.max else {
            throw Failure(reason: "Reseed requires retired previous branch and exact committed capture")
        }
        let id = BranchID(scope: scope, ordinal: nextBranch,
            snapshotFrontier: snapshotFrontier, initialSeedToken: seedToken, snapshotSHA256: snapshotSHA256)
        nextBranch += 1; branch = Branch(id: id, highestProducedPosition: inputFrontier)
        return id
    }

    /// Exactly one bounded credit may be outstanding. The worker may execute
    /// it concurrently with target verification, but may not exceed the grant.
    mutating func grant(_ count: Int) throws -> Grant {
        guard count > 0, count <= proposalCredit, var branch else {
            throw Failure(reason: "Proposal credit unavailable")
        }
        let value = Grant(branch: branch.id, firstPosition: branch.highestProducedPosition + 1, count: count)
        branch.outstanding = value; self.branch = branch
        return value
    }

    mutating func receive(_ grant: Grant, tokens: [Int]) throws {
        guard !requestStopped, var branch, !branch.cancelling,
              branch.id == grant.branch, branch.outstanding == grant,
              tokens.count == grant.count, tokens.allSatisfy(isToken),
              grant.firstPosition == branch.highestProducedPosition + 1,
              tokens.count <= maximumBufferedProposals - branch.proposals.count else {
            throw Failure(reason: "Late, replayed, foreign or oversized proposal delivery")
        }
        let incoming = tokens.enumerated().map { Proposal(position: grant.firstPosition + $0.offset, token: $0.element) }
        branch.proposals.append(contentsOf: incoming)
        branch.highestProducedPosition += tokens.count; branch.outstanding = nil
        counters.generated += tokens.count
        // Control ordering only; this does not prove GPU overlap or subtract
        // device clocks. Native phase observations are a separate obligation.
        if activeWindow != nil { counters.deliveredWhileTargetWindowOutstanding += tokens.count }
        reconcileBonusBridge(&branch)
        observeBonusEpoch(branch)
        self.branch = branch
    }

    /// Returned tokens are proposals only. A window can be selected only after
    /// its seed agrees with the authoritative target bonus/correction frontier.
    mutating func beginVerification(draftCount: Int) throws -> Window {
        guard !requestStopped, activeWindow == nil, pendingResolution == nil,
              let branch, !branch.cancelling, !branch.needsBonusBridge,
              (1...maximumDraftTokens).contains(draftCount),
              inputFrontier <= maximumInputFrontier - (draftCount + 1),
              bonusWindowAllowed(branch, draftCount: draftCount),
              branch.proposals.count >= draftCount, nextWindow < UInt64.max else {
            throw Failure(reason: "Target window unavailable or beyond admitted context")
        }
        let selected = Array(branch.proposals.prefix(draftCount))
        guard selected.enumerated().allSatisfy({ $0.element.position == inputFrontier + $0.offset + 1 }) else {
            throw Failure(reason: "Proposal positions differ from the target seed")
        }
        let window = Window(branch: branch.id, ordinal: nextWindow, seedPosition: inputFrontier,
            seedToken: seedToken, draftTokens: selected.map(\.token))
        nextWindow += 1; activeWindow = window
        counters.offered += draftCount
        if branch.id.snapshotFrontier < inputFrontier { counters.reusedProposalsOffered += draftCount }
        return window
    }

    /// Greedy-only: targetTokens are the actual argmaxes for every column in
    /// [seed, drafts]. Caller must obtain them from the real target under the
    /// existing fault/geometry/evaluation guards. No stochastic claim is made.
    mutating func resolve(_ window: Window, targetTokens: [Int]) throws -> Resolution {
        guard !requestStopped, activeWindow == window, pendingResolution == nil,
              targetTokens.count == window.draftTokens.count + 1,
              targetTokens.allSatisfy(isToken) else {
            throw Failure(reason: "Target verification result does not match its one live window")
        }
        var accepted = 0
        while accepted < window.draftTokens.count && window.draftTokens[accepted] == targetTokens[accepted] { accepted += 1 }
        let value = Resolution(window: window, acceptedDraftTokens: accepted,
            rejectedDraftTokens: window.draftTokens.count - accepted,
            nextInputFrontier: window.seedPosition + accepted + 1,
            targetConfirmedTokens: Array(targetTokens.prefix(accepted + 1)))
        pendingResolution = value
        return value
    }

    /// Only after actual target accepted-prefix reconcile/evaluation completes.
    /// This scalar join cannot establish that physical fact by itself.
    /// Output publication is permitted to the caller only after this returns.
    mutating func commit(_ value: Resolution, actualCommittedInputFrontier: Int,
                         targetEvaluationCompleted: Bool, rejectedSuffixReconciled: Bool) throws {
        guard !requestStopped, pendingResolution == value, activeWindow == value.window,
              var branch, branch.id == value.window.branch, !branch.cancelling,
              actualCommittedInputFrontier == value.nextInputFrontier,
              targetEvaluationCompleted, rejectedSuffixReconciled else {
            throw Failure(reason: "Target commit lacks exact reconciled frontier and completion")
        }
        inputFrontier = value.nextInputFrontier; seedToken = value.nextSeedToken
        counters.accepted += value.acceptedDraftTokens
        counters.committedOutputTokens += value.targetConfirmedTokens.count
        counters.committedWindows += 1
        activeWindow = nil; pendingResolution = nil
        if branch.bonusEpochFrontier != nil { branch.bonusEpochWindows += 1 }
        observeBonusEpoch(branch)
        if value.rejectedDraftTokens > 0 {
            branch.cancelling = true; counters.cancelledBranches += 1
        } else if bonusEpochNeedsRefresh(branch) {
            branch.cancelling = true; counters.cancelledBranches += 1
            counters.bonusBoundRetirements += 1
        } else {
            // The next seed is the target BONUS, not necessarily the next
            // assistant proposal. Check this extra bridge before reuse.
            branch.needsBonusBridge = true
            reconcileBonusBridge(&branch)
        }
        branch.proposals.removeAll { $0.position <= inputFrontier }
        self.branch = branch
    }

    private mutating func reconcileBonusBridge(_ branch: inout Branch) {
        guard branch.needsBonusBridge,
              let bridge = branch.proposals.first(where: { $0.position == inputFrontier }) else { return }
        if bridge.token == seedToken { branch.needsBonusBridge = false }
        else if bonusContinuationPolicy.enabled && !bonusEpochNeedsRefresh(branch) {
            // The target's BONUS remains seedToken. Never replace it with the
            // mismatching assistant bridge; only later proposals may be reused.
            let ready = branch.proposals.contains { $0.position == inputFrontier + 1 }
            if ready && maximumInputFrontier - inputFrontier >= 2 {
                if branch.bonusEpochFrontier == nil {
                    branch.bonusEpochFrontier = inputFrontier
                    branch.bonusEpochWindows = 0
                    counters.bonusEpochsStarted += 1
                }
                branch.needsBonusBridge = false
                counters.bonusMismatchesContinued += 1
                observeBonusEpoch(branch)
            } else {
                branch.cancelling = true; counters.cancelledBranches += 1
                counters.bonusNoReadyRetirements += 1
            }
        } else { branch.cancelling = true; counters.cancelledBranches += 1 }
        branch.proposals.removeAll { $0.position <= inputFrontier }
    }

    private func bonusWindowAllowed(_ branch: Branch, draftCount: Int) -> Bool {
        guard bonusContinuationPolicy.enabled else { return true }
        guard draftCount <= bonusContinuationPolicy.verificationDepth else { return false }
        guard let origin = branch.bonusEpochFrontier else { return true }
        return branch.bonusEpochWindows < AsyncMTPBonusContinuationPolicy.maximumWindows
            && inputFrontier + draftCount + 1 - origin <= AsyncMTPBonusContinuationPolicy.maximumPositions
    }

    private func bonusEpochNeedsRefresh(_ branch: Branch) -> Bool {
        guard let origin = branch.bonusEpochFrontier else { return false }
        let remaining = maximumInputFrontier - inputFrontier
        // The final single seed is an ordinary target-only step. Otherwise
        // preflight the actual next narrowed D1/D2 verification width.
        let nextWidth = remaining >= 2 ? min(bonusContinuationPolicy.verificationDepth + 1, remaining) : 0
        return branch.bonusEpochWindows >= AsyncMTPBonusContinuationPolicy.maximumWindows
            || inputFrontier - origin + nextWidth > AsyncMTPBonusContinuationPolicy.maximumPositions
    }

    private mutating func observeBonusEpoch(_ branch: Branch) {
        guard let origin = branch.bonusEpochFrontier else { return }
        counters.bonusMaximumWindows = max(counters.bonusMaximumWindows, branch.bonusEpochWindows)
        counters.bonusMaximumInputAdvance = max(counters.bonusMaximumInputAdvance, inputFrontier - origin)
        counters.bonusMaximumProducedAdvance = max(counters.bonusMaximumProducedAdvance, branch.highestProducedPosition - origin)
    }

    var bonusContinuationReport: AsyncMTPBonusContinuationReport? {
        guard bonusContinuationPolicy.enabled else { return nil }
        return .init(verificationDepth: bonusContinuationPolicy.verificationDepth,
            epochsStarted: counters.bonusEpochsStarted, bonusMismatchesContinued: counters.bonusMismatchesContinued,
            boundRetirementDecisions: counters.bonusBoundRetirements, noReadyRetirementDecisions: counters.bonusNoReadyRetirements,
            maximumObservedWindows: counters.bonusMaximumWindows, maximumObservedInputAdvance: counters.bonusMaximumInputAdvance,
            maximumObservedProducedAdvance: counters.bonusMaximumProducedAdvance)
    }

    mutating func cancelRequest() {
        requestCancelled = true
        if var branch, !branch.cancelling {
            branch.cancelling = true; counters.cancelledBranches += 1; self.branch = branch
        }
        // Never infer target or remote completion, nor clear outstanding work.
    }

    mutating func finishRequest() throws {
        guard !requestStopped, activeWindow == nil, pendingResolution == nil else {
            throw Failure(reason: "Successful completion has unresolved target work")
        }
        requestCompleted = true
        if var branch, !branch.cancelling {
            branch.cancelling = true; counters.cancelledBranches += 1; self.branch = branch
        }
    }

    /// The existing owner must join its actual target abort/reconcile first.
    mutating func targetAborted(_ window: Window, evaluationCompleted: Bool, requestStateRetired: Bool) throws {
        guard requestCancelled, activeWindow == window, evaluationCompleted, requestStateRetired else {
            throw Failure(reason: "Target abort lacks completed request-state retirement")
        }
        activeWindow = nil; pendingResolution = nil
    }

    /// Must follow the real branch worker fence and every payload lease release.
    /// Even after cancellation, no replacement branch may start before this ACK.
    mutating func branchRetired(_ id: BranchID, nativeWorkCompleted: Bool, payloadLeasesReleased: Bool) throws {
        guard let branch, branch.id == id, branch.cancelling,
              nativeWorkCompleted, payloadLeasesReleased else {
            throw Failure(reason: "Branch retirement lacks its exact native/payload fence")
        }
        self.branch = nil
    }

    var controlStateRetired: Bool { requestStopped && branch == nil && activeWindow == nil && pendingResolution == nil }
    private func isToken(_ value: Int) -> Bool { (0..<vocabularySize).contains(value) }
    private static func isSHA(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
