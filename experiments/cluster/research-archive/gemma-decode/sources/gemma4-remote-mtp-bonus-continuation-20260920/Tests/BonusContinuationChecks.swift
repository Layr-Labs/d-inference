import Foundation

@main enum BonusContinuationChecks {
    struct Failure: Error { let reason: String }
    static let hash = String(repeating: "a", count: 64)
    static var scope: AsyncMTPProposalLedger.Scope { .init(
        requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        membershipEpoch: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        targetBuildSHA256: hash, assistantBuildSHA256: hash,
        targetArtifactSHA256: hash, assistantArtifactSHA256: hash, embeddingIdentitySHA256: hash) }
    static func require(_ value: Bool, _ why: String) throws { if !value { throw Failure(reason: why) } }
    static func refuses(_ work: () throws -> Void) throws {
        do { try work() } catch { return }; throw Failure(reason: "expected refusal")
    }
    static func policy(_ depth: Int) throws -> AsyncMTPBonusContinuationPolicy {
        try .init(explicitPolicy: AsyncMTPBonusContinuationPolicy.name, verificationDepth: depth)
    }
    static func ledger(_ depth: Int = 1, enabled: Bool = true, end: Int = 1000) throws -> AsyncMTPProposalLedger {
        var value = try AsyncMTPProposalLedger(scope: scope, inputFrontier: 129, seedToken: 7,
            maximumDraftTokens: 2, maximumInputFrontier: end, vocabularySize: 262_144,
            bonusContinuationPolicy: enabled ? policy(depth) : .strict)
        _ = try value.startBranch(snapshotFrontier: 129, snapshotSHA256: hash)
        return value
    }
    static func deliver(_ tokens: [Int], _ value: inout AsyncMTPProposalLedger) throws {
        let grant = try value.grant(tokens.count); try value.receive(grant, tokens: tokens)
    }
    static func deliverCredit(_ value: inout AsyncMTPProposalLedger) throws {
        if value.proposalCredit > 0 {
            let grant = try value.grant(min(2, value.proposalCredit))
            try value.receive(grant, tokens: (grant.firstPosition..<(grant.firstPosition+grant.count)).map { $0+1000 })
        }
    }
    static func commit(_ tokens: [Int], _ window: AsyncMTPProposalLedger.Window,
                       _ value: inout AsyncMTPProposalLedger) throws {
        let result = try value.resolve(window, targetTokens: tokens)
        try value.commit(result, actualCommittedInputFrontier: result.nextInputFrontier,
                         targetEvaluationCompleted: true, rejectedSuffixReconciled: true)
    }
    /// Target results below are explicit scalar fixtures, never native claims.
    @discardableResult static func step(_ depth: Int, mismatch: Bool,
                                      _ value: inout AsyncMTPProposalLedger) throws -> AsyncMTPProposalLedger.Window {
        try deliverCredit(&value)
        let window = try value.beginVerification(draftCount: depth)
        try deliverCredit(&value)
        let bonus = window.seedPosition+depth+1+1000+(mismatch ? 10_000 : 0)
        try commit(window.draftTokens+[bonus], window, &value)
        return window
    }

    static func main() throws {
        var passed: [String] = []
        func test(_ name: String, _ body: () throws -> Void) throws { try body(); passed.append(name) }
        try test("closedPolicyAndNilDefault") {
            for depth in 1...2 {
                let absent = try AsyncMTPBonusContinuationPolicy(explicitPolicy: nil, verificationDepth: depth)
                try require(absent == .strict && absent.scopeComponents.isEmpty, "strict absent policy")
                try require(try policy(depth).scopeComponents == ["bonusContinuationPolicy=bounded_stale_bonus_v1",
                    "bonusContinuationWindows=16", "bonusContinuationPositions=32"], "exact scope")
            }
            try refuses { _ = try AsyncMTPBonusContinuationPolicy(explicitPolicy: "other", verificationDepth: 1) }
            try refuses { _ = try AsyncMTPBonusContinuationPolicy(explicitPolicy: nil, verificationDepth: 3) }
        }
        try test("strictBonusMismatchStillRetires") {
            for depth in 1...2 {
                var value = try ledger(depth, enabled: false)
                _ = try step(depth, mismatch: true, &value)
                try require(value.requiresBranchRetirement && value.bonusContinuationReport == nil, "strict behavior")
            }
        }
        try test("D1ActualBonusRemainsNextSeed") {
            var value = try ledger()
            try deliver([11,21], &value); let first = try value.beginVerification(draftCount: 1)
            try deliver([22,23], &value); try commit([11,12], first, &value)
            let next = try value.beginVerification(draftCount: 1)
            try require(next.seedToken == 12 && next.seedPosition == 131 && next.draftTokens == [22], "never use assistant21 as seed")
            try require(value.bonusContinuationReport?.epochsStarted == 1 && !value.requiresBranchRetirement, "one bounded epoch")
        }
        try test("D2AllAcceptedBonusMismatchKeepsReadyContinuation") {
            var value = try ledger(2)
            try deliver([11,12], &value); let first = try value.beginVerification(draftCount: 2)
            try deliver([21,22], &value); try commit([11,12,13], first, &value)
            try require(!value.requiresBranchRetirement && value.seedToken == 13, "D2 actual bonus")
            try deliver([23,24], &value); let next = try value.beginVerification(draftCount: 2)
            try require(next.seedPosition == 132 && next.draftTokens == [22,23], "one ready then ordinary refill")
            try commit([22,23,24], next, &value)
            try require(value.bonusContinuationReport?.maximumObservedWindows == 1, "epoch advances once")
        }
        try test("draftRejectionStillRetiresBeforeReuse") {
            for depth in 1...2 {
                var value = try ledger(depth); _ = try step(depth, mismatch: true, &value)
                try deliverCredit(&value); let window = try value.beginVerification(draftCount: depth)
                try deliverCredit(&value); try commit(Array(repeating: 262_000, count: depth+1), window, &value)
                try require(value.requiresBranchRetirement, "rejection remains strict")
                try refuses { _ = try value.beginVerification(draftCount: 1) }
            }
        }
        try test("partialD2AcceptanceCannotUseBonusPolicy") {
            var value = try ledger(2)
            try deliver([11,12], &value); let window = try value.beginVerification(draftCount: 2)
            try deliver([13,14], &value); try commit([11,99,88], window, &value)
            try require(value.requiresBranchRetirement && value.bonusContinuationReport?.epochsStarted == 0, "partial prefix retires")
        }
        try test("noReadyProposalKeepsStrictRetirement") {
            for depth in 1...2 {
                var value = try ledger(depth)
                if depth == 1 {
                    try deliver([11,21], &value); let window = try value.beginVerification(draftCount: 1)
                    try commit([11,12], window, &value)
                } else {
                    try deliver([11,12], &value); let window = try value.beginVerification(draftCount: 2)
                    try deliver([21], &value); try commit([11,12,13], window, &value)
                }
                try require(value.requiresBranchRetirement && value.bonusContinuationReport?.noReadyRetirementDecisions == 1,
                    "no fabricated future continuation")
            }
        }
        try test("matchingBranchesHaveNoNewPeriodicResets") {
            for depth in 1...2 {
                var value = try ledger(depth)
                for _ in 0..<24 { _ = try step(depth, mismatch: false, &value) }
                let report = value.bonusContinuationReport!
                try require(!value.requiresBranchRetirement && report.epochsStarted == 0 && report.boundRetirementDecisions == 0,
                    "strict matching branch unchanged beyond16windows32positions")
            }
        }
        try test("epochStartsAtFirstMismatchAndNeverRestarts") {
            for depth in 1...2 {
                var value = try ledger(depth)
                for _ in 0..<20 { _ = try step(depth, mismatch: false, &value) }
                _ = try step(depth, mismatch: true, &value)
                let initial = value.bonusContinuationReport!
                try require(initial.epochsStarted == 1 && initial.maximumObservedWindows == 0 && initial.maximumObservedInputAdvance == 0,
                    "first mismatch is the epoch origin")
                var steps = 0
                while !value.requiresBranchRetirement && steps < 20 { _ = try step(depth, mismatch: true, &value); steps += 1 }
                let report = value.bonusContinuationReport!
                try require(value.requiresBranchRetirement && report.epochsStarted == 1 && report.boundRetirementDecisions == 1,
                    "repeated mismatches cannot restart bound")
                try require(report.maximumObservedWindows <= 16 && report.maximumObservedInputAdvance <= 32
                    && report.maximumObservedProducedAdvance <= 32, "windows and produced positions bounded")
                try require(steps == (depth == 1 ? 16 : 10), "D1 window bound / D2 preflight position bound")
                try require(value.proposalCredit == 0, "bounded epoch cannot produce more work")
            }
        }
        try test("freshSeedResetsEpochOnlyAfterActualRetirementJoin") {
            var value = try ledger(); let first = try step(1, mismatch: true, &value)
            for _ in 0..<16 { _ = try step(1, mismatch: false, &value) }
            try refuses { _ = try value.startBranch(snapshotFrontier: value.inputFrontier, snapshotSHA256: hash) }
            try refuses { try value.branchRetired(first.branch, nativeWorkCompleted: false, payloadLeasesReleased: true) }
            try value.branchRetired(first.branch, nativeWorkCompleted: true, payloadLeasesReleased: true)
            _ = try value.startBranch(snapshotFrontier: value.inputFrontier, snapshotSHA256: hash)
            for _ in 0..<20 { _ = try step(1, mismatch: false, &value) }
            try require(!value.requiresBranchRetirement && value.bonusContinuationReport?.epochsStarted == 1,
                "fresh matching branch has no old epoch")
        }
        try test("D2TerminalWidthNarrowsWithoutExtraProposalOrOvershoot") {
            var value = try ledger(2, end: 134)
            try deliver([11,12], &value); let first = try value.beginVerification(draftCount: 2)
            try deliver([21,22], &value); try commit([11,12,13], first, &value)
            try require(!value.requiresBranchRetirement && value.proposalCredit == 1, "terminal actual remaining credit")
            try deliver([23], &value); let last = try value.beginVerification(draftCount: 1)
            try require(last.seedToken == 13 && last.draftTokens == [22], "narrow actual seed/window")
            try commit([22,99], last, &value)
            try require(value.inputFrontier == 134 && value.seedToken == 99 && value.requiresBranchRetirement, "end cannot reuse unavailable continuation")
            try value.finishRequest(); try value.branchRetired(first.branch, nativeWorkCompleted: true, payloadLeasesReleased: true)
            try require(value.controlStateRetired, "original finish retirement")
        }
        try test("completionAndReplayRequirementsRemainMandatory") {
            var value = try ledger(); _ = try step(1, mismatch: true, &value)
            try deliverCredit(&value); let window = try value.beginVerification(draftCount: 1)
            let decision = try value.resolve(window, targetTokens: [window.draftTokens[0],99])
            try refuses { try value.commit(decision, actualCommittedInputFrontier: decision.nextInputFrontier,
                targetEvaluationCompleted: false, rejectedSuffixReconciled: true) }
            value.cancelRequest()
            try refuses { try value.commit(decision, actualCommittedInputFrontier: decision.nextInputFrontier,
                targetEvaluationCompleted: true, rejectedSuffixReconciled: true) }
            try require(!value.controlStateRetired, "cancel never infers native retirement")
        }
        try test("realTargetAndMirrorAgreeOnBonusContinuation") {
            for depth in 1...2 { try mirrorRound(depth) }
        }
        try require(passed.count == 13, "exact control count")
        let bytes = try JSONSerialization.data(withJSONObject: ["schema":"gemma4_bonus_continuation_checks_v1",
            "passed":passed,"nativeExecuted":false,"targetMathQualified":false],options:[.sortedKeys])
        print(String(decoding:bytes,as:UTF8.self))
    }

    static func mirrorRound(_ depth: Int) throws {
        let p = try policy(depth)
        let mirror = try Gemma4MTPPullMirror(scope:scope,requestSHA256:hash,inputFrontier:129,seed:7,
            maximumInputFrontier:255,bonusContinuationPolicy:p)
        var target = try AsyncMTPProposalLedger(scope:scope,inputFrontier:129,seedToken:7,maximumDraftTokens:2,
            maximumInputFrontier:255,vocabularySize:262_144,bonusContinuationPolicy:p)
        let capture = Gemma4MTPPullRecord.captureFingerprint(scope:mirror.scopeSHA256,ordinal:0,frontier:129,seed:7,hiddenDType:3)
        let branch = try target.startBranch(snapshotFrontier:129,snapshotSHA256:capture)
        var sequence: UInt64 = 0
        func record(_ kind: Gemma4MTPPullRecord.Kind) -> Gemma4MTPPullRecord {
            .init(kind:kind,sequence:sequence,scopeSHA256:mirror.scopeSHA256,branch:branch)
        }
        func response(_ kind: Gemma4MTPPullRecord.Kind) throws {
            _ = try mirror.response(kind); try mirror.responseSent(); sequence += 1
        }
        var seed = record(.seed); seed.frontier = 129; seed.seed = 7; seed.hiddenDType = 3
        guard case .install = try mirror.accept(seed) else { throw Failure(reason:"seed action") }; try response(.seeded)
        func delivery(_ tokens: [Int]) throws {
            let grant = try target.grant(tokens.count)
            var credit = record(.credit); credit.frontier = target.inputFrontier; credit.seed = target.seedToken
            credit.firstPosition = grant.firstPosition; credit.count = grant.count
            guard case .generate(let same) = try mirror.accept(credit), same == grant else { throw Failure(reason:"grant action") }
            try response(.queued); try mirror.generationCompleted(grant,tokens:tokens)
            var pull = record(.pull); pull.firstPosition = grant.firstPosition; pull.count = grant.count
            guard case .deliver(let sameTokens) = try mirror.accept(pull), sameTokens == tokens else { throw Failure(reason:"pull action") }
            try response(.proposals); try target.receive(grant,tokens:tokens)
        }
        try delivery(depth == 1 ? [11,21] : [11,12])
        let window = try target.beginVerification(draftCount:depth)
        try delivery(depth == 1 ? [22,23] : [21,22])
        let tokens = depth == 1 ? [11,12] : [11,12,13]
        let resolution = try target.resolve(window,targetTokens:tokens)
        try target.commit(resolution,actualCommittedInputFrontier:resolution.nextInputFrontier,
            targetEvaluationCompleted:true,rejectedSuffixReconciled:true)
        var command = record(.resolve); command.count = depth; command.windowOrdinal = window.ordinal
        command.frontier = resolution.nextInputFrontier; command.seed = resolution.nextSeedToken
        command.accepted = depth; command.tokens = tokens
        guard case .resolved = try mirror.accept(command) else { throw Failure(reason:"resolution action") }
        try response(.resolved)
        try require(target.seedToken == tokens.last! && mirror.ledger.seedToken == target.seedToken,
            "both mirrors keep authoritative target bonus")
        try require(!target.requiresBranchRetirement && !mirror.ledger.requiresBranchRetirement
            && target.bonusContinuationReport == mirror.ledger.bonusContinuationReport, "same bounded policy state")
        let cancel = record(.cancel); _ = try mirror.accept(cancel); try response(.cancelled)
        target.cancelRequest(); try target.branchRetired(branch,nativeWorkCompleted:true,payloadLeasesReleased:true)
        try require(target.controlStateRetired && mirror.ledger.controlStateRetired, "same existing cancellation retirement")
    }
}
