import Foundation

/// Runs the retained actual scalar ledger/mirror, not a replacement queue.
/// These controls establish no native completion, correctness or speed claim.
@main enum RefillPolicyChecks {
    struct Failure: Error { let reason: String }
    static let hash = String(repeating: "a", count: 64)
    static var scope: AsyncMTPProposalLedger.Scope { .init(
        requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        membershipEpoch: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        targetBuildSHA256: hash, assistantBuildSHA256: hash,
        targetArtifactSHA256: hash, assistantArtifactSHA256: hash, embeddingIdentitySHA256: hash) }
    static func require(_ value: Bool, _ reason: String) throws {
        guard value else { throw Failure(reason: reason) }
    }
    static func refuses(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw Failure(reason: "expected refusal")
    }
    static func ledger() throws -> AsyncMTPProposalLedger {
        try .init(scope: scope, inputFrontier: 129, seedToken: 7,
                  maximumDraftTokens: 2, maximumInputFrontier: 255, vocabularySize: 262_144)
    }
    static func started() throws -> AsyncMTPProposalLedger {
        var value = try ledger()
        _ = try value.startBranch(snapshotFrontier: 129, snapshotSHA256: hash)
        return value
    }
    static func single() throws -> Gemma4RemoteMTPRefillPolicy {
        try .init(explicitPolicy: "single_for_depth_one_v1", verificationDepth: 1)
    }
    static func deliver(_ count: Int, _ tokens: [Int], _ value: inout AsyncMTPProposalLedger) throws {
        let grant = try value.grant(count)
        try value.receive(grant, tokens: tokens)
    }
    static func commit(_ tokens: [Int], _ window: AsyncMTPProposalLedger.Window,
                       _ value: inout AsyncMTPProposalLedger) throws {
        let result = try value.resolve(window, targetTokens: tokens)
        try value.commit(result, actualCommittedInputFrontier: result.nextInputFrontier,
                         targetEvaluationCompleted: true, rejectedSuffixReconciled: true)
    }

    static func main() throws {
        var passed: [String] = []
        func test(_ name: String, _ body: () throws -> Void) throws { try body(); passed.append(name) }
        try test("missingPolicyKeepsExactPairedGrantAtBothDepths") {
            for depth in 1...2 {
                let policy = try Gemma4RemoteMTPRefillPolicy(explicitPolicy: nil, verificationDepth: depth)
                try require(policy == .paired && policy.scopeComponents.isEmpty, "legacy scope")
                for credit in 0...2 {
                    try require(try policy.exposedGrant(draftCount: depth, proposalCredit: credit) == min(2, credit), "legacy expression")
                }
            }
        }
        try test("explicitSingleRefillRequiresD1AndExactPolicy") {
            try refuses { _ = try Gemma4RemoteMTPRefillPolicy(explicitPolicy: "single_for_depth_one_v1", verificationDepth: 2) }
            try refuses { _ = try Gemma4RemoteMTPRefillPolicy(explicitPolicy: "paired_v1", verificationDepth: 1) }
            try refuses { _ = try Gemma4RemoteMTPRefillPolicy(explicitPolicy: "single", verificationDepth: 1) }
            try refuses { _ = try Gemma4RemoteMTPRefillPolicy(explicitPolicy: nil, verificationDepth: 0) }
            let value = try single()
            try require(value.scopeComponents == ["producerRefillPolicy=single_for_depth_one_v1", "producerLookaheadGrant=2"], "bilateral policy scope")
        }
        try test("singleRefillCannotCreateOrExceedCredit") {
            let policy = try single()
            for credit in [0, -1, 3, Int.max] {
                try refuses { _ = try policy.exposedGrant(draftCount: 1, proposalCredit: credit) }
            }
            try refuses { _ = try policy.exposedGrant(draftCount: 2, proposalCredit: 2) }
            for credit in 1...2 { try require(try policy.exposedGrant(draftCount: 1, proposalCredit: credit) == 1, "single grant") }
        }
        try test("actualLedgerUsesOneExposedThenTwoOverlapped") {
            var value = try started(); let policy = try single()
            let count = try policy.exposedGrant(draftCount: 1, proposalCredit: value.proposalCredit)
            try deliver(count, [11], &value)
            let window = try value.beginVerification(draftCount: 1)
            let overlap = try value.grant(min(2, value.proposalCredit))
            try require(overlap.count == 2 && value.proposalCredit == 0, "one outstanding grant")
            try value.receive(overlap, tokens: [12, 13])
            try commit([11, 12], window, &value)
            let next = try value.beginVerification(draftCount: 1)
            try require(next.draftTokens == [13] && next.seedToken == 12 && next.seedPosition == 131, "ready after bonus bridge")
            try require(value.maximumDraftTokens == 2 && value.maximumBufferedProposals == 5, "unchanged ledger envelope")
        }
        try test("preservedBranchNeedsNoNewExposedRefillAcrossNextWindow") {
            var value = try started()
            try deliver(1, [11], &value)
            let first = try value.beginVerification(draftCount: 1)
            try deliver(2, [12, 13], &value)
            try commit([11, 12], first, &value)
            let second = try value.beginVerification(draftCount: 1)
            try deliver(2, [14, 15], &value)
            try commit([13, 14], second, &value)
            let third = try value.beginVerification(draftCount: 1)
            try require(third.draftTokens == [15] && value.counters.reusedProposalsOffered == 2, "reuse after two bridges")
        }
        try test("allSingleGrantsWouldStarveAfterMatchingBonus") {
            var value = try started()
            try deliver(1, [11], &value)
            let first = try value.beginVerification(draftCount: 1)
            try deliver(1, [12], &value) // Negative scheduling control, NOT candidate.
            try commit([11, 12], first, &value)
            try require(!value.requiresBranchRetirement && value.inputFrontier == 131, "valid bridge")
            try refuses { _ = try value.beginVerification(draftCount: 1) }
        }
        try test("rejectionStillRequiresDrainAndExactBranchRetirement") {
            var value = try started()
            try deliver(1, [11], &value)
            let first = try value.beginVerification(draftCount: 1)
            let overlap = try value.grant(2)
            try value.receive(overlap, tokens: [12, 13])
            try commit([99, 88], first, &value)
            try require(value.requiresBranchRetirement && value.inputFrontier == 130, "target rejection")
            try refuses { _ = try value.startBranch(snapshotFrontier: 130, snapshotSHA256: hash) }
            try refuses { try value.branchRetired(first.branch, nativeWorkCompleted: false, payloadLeasesReleased: true) }
            try value.branchRetired(first.branch, nativeWorkCompleted: true, payloadLeasesReleased: true)
            let next = try value.startBranch(snapshotFrontier: 130, snapshotSHA256: hash)
            try require(next.ordinal == 1 && next.initialSeedToken == 99, "authoritative reseed")
        }
        try test("bonusMismatchCannotReuseOldAssistantBranch") {
            var value = try started()
            try deliver(1, [11], &value)
            let first = try value.beginVerification(draftCount: 1)
            try deliver(2, [21, 22], &value)
            try commit([11, 12], first, &value)
            try require(value.requiresBranchRetirement, "mismatching bonus retires")
            try refuses { _ = try value.beginVerification(draftCount: 1) }
        }
        try test("oneCreditCannotBeReplayedDuplicatedOrPublishedAfterCancel") {
            var value = try started(); let grant = try value.grant(1)
            try refuses { _ = try value.grant(1) }
            try value.receive(grant, tokens: [11])
            try refuses { try value.receive(grant, tokens: [11]) }
            let next = try value.grant(2)
            value.cancelRequest()
            try refuses { try value.receive(next, tokens: [12, 13]) }
            try require(!value.canReseed && !value.controlStateRetired, "cancellation retains retirement obligation")
        }
        try test("pairedD2StillVerifiesTwoAndKeepsFiveSlotBound") {
            var value = try started()
            let policy = try Gemma4RemoteMTPRefillPolicy(explicitPolicy: nil, verificationDepth: 2)
            try deliver(policy.exposedGrant(draftCount: 2, proposalCredit: value.proposalCredit), [11, 12], &value)
            let window = try value.beginVerification(draftCount: 2)
            try deliver(2, [13, 14], &value)
            try commit([11, 12, 13], window, &value)
            try require(!value.requiresBranchRetirement && value.seedToken == 13 && value.maximumBufferedProposals == 5, "D2 exact legacy behavior")
        }
        try test("actualMirrorAcceptsSingleGrantOnlyAfterInstalledSeedAndQueuedACK") {
            let mirror = try Gemma4MTPPullMirror(scope: scope, requestSHA256: hash,
                inputFrontier: 129, seed: 7, maximumInputFrontier: 255)
            var target = try ledger()
            let captureID = Gemma4MTPPullRecord.captureFingerprint(scope: mirror.scopeSHA256, ordinal: 0, frontier: 129, seed: 7, hiddenDType: 3)
            let branch = try target.startBranch(snapshotFrontier: 129, snapshotSHA256: captureID)
            var seed = Gemma4MTPPullRecord(kind: .seed, sequence: 0, scopeSHA256: mirror.scopeSHA256, branch: branch)
            seed.frontier = 129; seed.seed = 7; seed.hiddenDType = 3
            guard case .install(let actual) = try mirror.accept(seed) else { throw Failure(reason: "install action") }
            try require(actual == branch, "same branch")
            _ = try mirror.response(.seeded); try mirror.responseSent()
            let grant = try target.grant(1)
            var credit = Gemma4MTPPullRecord(kind: .credit, sequence: 1, scopeSHA256: mirror.scopeSHA256, branch: branch)
            credit.frontier = 129; credit.seed = 7; credit.firstPosition = grant.firstPosition; credit.count = 1
            guard case .generate(let actualGrant) = try mirror.accept(credit) else { throw Failure(reason: "generate action") }
            try require(actualGrant == grant, "exact single grant")
            // The real worker prepares here; actual native execution still may
            // begin only after completed queued ACK, as the unchanged service does.
            _ = try mirror.response(.queued); try mirror.responseSent()
            try mirror.generationCompleted(grant, tokens: [11])
            var pull = Gemma4MTPPullRecord(kind: .pull, sequence: 2, scopeSHA256: mirror.scopeSHA256, branch: branch)
            pull.firstPosition = grant.firstPosition; pull.count = 1
            guard case .deliver(let tokens) = try mirror.accept(pull) else { throw Failure(reason: "deliver action") }
            try require(tokens == [11], "bounded actual mirror result")
            let reply = try mirror.response(.proposals); try mirror.responseSent()
            try target.receive(grant, tokens: reply.tokens)
            try require(try target.beginVerification(draftCount: 1).draftTokens == [11], "same target window")
            try refuses { _ = try mirror.accept(pull) }
        }
        let data = try JSONSerialization.data(withJSONObject: ["schema": "gemma4_remote_mtp_refill_policy_checks_v1", "passed": passed, "nativeExecuted": false], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
