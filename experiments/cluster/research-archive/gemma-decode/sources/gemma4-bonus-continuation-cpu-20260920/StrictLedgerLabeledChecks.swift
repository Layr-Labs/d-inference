import Foundation

private typealias Ledger = AsyncMTPProposalLedger
private struct CheckFailure: Error { let label: String }
private func check(_ value: Bool, _ label: String) throws { if !value { throw CheckFailure(label: label) } }
private func refuses(_ label: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw CheckFailure(label: "Unexpected acceptance: " + label)
}
private func fresh(depth: Int = 2, vocabulary: Int = 262144, seed: Int = 100) throws -> Ledger {
    let scope = Ledger.Scope(requestID: UUID(), membershipEpoch: UUID(),
        targetBuildSHA256: String(repeating: "1", count: 64), assistantBuildSHA256: String(repeating: "2", count: 64),
        targetArtifactSHA256: String(repeating: "3", count: 64), assistantArtifactSHA256: String(repeating: "4", count: 64),
        embeddingIdentitySHA256: String(repeating: "5", count: 64))
    return try Ledger(scope: scope, inputFrontier: 4096, seedToken: seed,
        maximumDraftTokens: depth, maximumInputFrontier: 8192, vocabularySize: vocabulary)
}
private func start(_ ledger: inout Ledger) throws -> Ledger.BranchID {
    try ledger.startBranch(snapshotFrontier: ledger.inputFrontier, snapshotSHA256: String(repeating: "a", count: 64))
}
private func feed(_ ledger: inout Ledger, _ tokens: [Int]) throws {
    let grant = try ledger.grant(tokens.count); try ledger.receive(grant, tokens: tokens)
}
private func commit(_ ledger: inout Ledger, _ result: Ledger.Resolution) throws {
    try ledger.commit(result, actualCommittedInputFrontier: result.nextInputFrontier,
        targetEvaluationCompleted: true, rejectedSuffixReconciled: true)
}

@main enum ProposalLedgerCheck {
    static func main() throws {
        var groups = 0
        var passed: [String] = []
        do {
            var ledger = try fresh(); let branch = try start(&ledger)
            try feed(&ledger, [101, 102]); let window = try ledger.beginVerification(draftCount: 2)
            try feed(&ledger, [103, 104]); try feed(&ledger, [105]) // while target window remains outstanding
            let result = try ledger.resolve(window, targetTokens: [101, 102, 103])
            try check(ledger.inputFrontier == 4096 && ledger.counters.accepted == 0, "Resolution is not a target commit")
            try commit(&ledger, result)
            let next = try ledger.beginVerification(draftCount: 2)
            try check(next.branch == branch && next.seedPosition == 4099 && next.seedToken == 103
                && next.draftTokens == [104,105], "Full prefix plus bonus bridge reuses exact continuation")
            try check(ledger.counters.reusedProposalsOffered == 2
                && ledger.counters.deliveredWhileTargetWindowOutstanding == 3, "Separate stale reuse/control delivery counts")
            groups += 1
            passed.append("strictFullPrefixAndBonusReusesContinuation")
        }
        do {
            var ledger = try fresh(); let branch = try start(&ledger)
            try feed(&ledger, [101,102]); let window = try ledger.beginVerification(draftCount: 2)
            try feed(&ledger, [999,104])
            let resolved = try ledger.resolve(window, targetTokens: [101,102,103])
            try commit(&ledger, resolved)
            try check(ledger.requiresBranchRetirement && !ledger.canReseed, "All drafts accepted but bonus bridge mismatch discards")
            try refuses("reuse after bonus mismatch") { _ = try ledger.beginVerification(draftCount: 1) }
            try refuses("premature branch replacement") { _ = try start(&ledger) }
            try ledger.branchRetired(branch, nativeWorkCompleted: true, payloadLeasesReleased: true)
            let next = try start(&ledger)
            try check(next.ordinal == branch.ordinal + 1 && next.initialSeedToken == 103 && next.snapshotFrontier == 4099, "Fresh reseed after actual branch fence")
            groups += 1
            passed.append("strictBonusMismatchRequiresRetirement")
        }
        do {
            var ledger = try fresh(); _ = try start(&ledger); try feed(&ledger,[101,102])
            let window = try ledger.beginVerification(draftCount: 2)
            let result = try ledger.resolve(window, targetTokens:[101,777,999])
            try check(result.acceptedDraftTokens == 1 && result.rejectedDraftTokens == 1
                && result.targetConfirmedTokens == [101,777] && result.nextInputFrontier == 4098, "First divergence target correction")
            try commit(&ledger,result); try check(ledger.requiresBranchRetirement, "Rejected suffix cannot continue")
            groups += 1
            passed.append("strictPartialAcceptanceCommitsTargetCorrection")
        }
        do {
            var ledger = try fresh(); _ = try start(&ledger); try feed(&ledger,[101,102])
            let window = try ledger.beginVerification(draftCount: 2)
            let result = try ledger.resolve(window,targetTokens:[777,102,103])
            try check(result.targetConfirmedTokens == [777] && result.acceptedDraftTokens == 0
                && result.nextInputFrontier == 4097, "Zero accepted still commits only authoritative seed input")
            groups += 1
            passed.append("strictZeroAcceptanceCommitsAuthoritativeSeed")
        }
        do {
            var ledger = try fresh(); _ = try start(&ledger); try feed(&ledger,[101,102])
            let window = try ledger.beginVerification(draftCount: 2)
            let result = try ledger.resolve(window,targetTokens:[101,102,103]); try commit(&ledger,result)
            try refuses("next round before bridge delivery") { _ = try ledger.beginVerification(draftCount:1) }
            try feed(&ledger,[103,104]); let next = try ledger.beginVerification(draftCount:1)
            try check(next.draftTokens == [104], "Late exact bonus bridge is consumed, not offered twice")
            groups += 1
            passed.append("strictLateBonusBridgeIsConsumedOnce")
        }
        do {
            var ledger = try fresh(); _ = try start(&ledger); let grant = try ledger.grant(2)
            try refuses("overlapping credit") { _ = try ledger.grant(1) }
            try refuses("wrong count") { try ledger.receive(grant,tokens:[101]) }
            try refuses("vocabulary") { try ledger.receive(grant,tokens:[101,262144]) }
            try ledger.receive(grant,tokens:[101,102])
            try refuses("duplicate delivery") { try ledger.receive(grant,tokens:[101,102]) }
            groups += 1
            passed.append("strictGrantIdentityCountVocabularyAndReplay")
        }
        do {
            var ledger = try fresh(); _ = try start(&ledger); try feed(&ledger,[101,102]); try feed(&ledger,[103,104]); try feed(&ledger,[105])
            try check(ledger.proposalCredit == 0, "2k+1 buffer bound")
            try refuses("unbounded speculation") { _ = try ledger.grant(1) }
            groups += 1
            passed.append("strictFiveProposalBufferCap")
        }
        do {
            var a = try fresh(); var b = try fresh(); _ = try start(&a); _ = try start(&b)
            let foreign = try b.grant(1)
            try refuses("foreign request/epoch") { try a.receive(foreign,tokens:[101]) }
            groups += 1
            passed.append("strictForeignRequestAndEpochRefused")
        }
        do {
            var ledger = try fresh(); _ = try start(&ledger); try feed(&ledger,[101,102])
            let window = try ledger.beginVerification(draftCount:2)
            try refuses("second target window") { _ = try ledger.beginVerification(draftCount:1) }
            try refuses("missing target bonus column") { _ = try ledger.resolve(window,targetTokens:[101,102]) }
            let result = try ledger.resolve(window,targetTokens:[101,102,103])
            try refuses("duplicate resolution") { _ = try ledger.resolve(window,targetTokens:[101,102,103]) }
            try refuses("wrong commit frontier") { try ledger.commit(result,actualCommittedInputFrontier:4098,targetEvaluationCompleted:true,rejectedSuffixReconciled:true) }
            try refuses("unfenced target") { try ledger.commit(result,actualCommittedInputFrontier:4099,targetEvaluationCompleted:false,rejectedSuffixReconciled:true) }
            try commit(&ledger,result)
            try refuses("replayed target commit") { try commit(&ledger,result) }
            groups += 1
            passed.append("strictTargetWindowResolutionAndCommitFences")
        }
        do {
            var ledger = try fresh(); let branch = try start(&ledger); try feed(&ledger,[101,102])
            let window = try ledger.beginVerification(draftCount:2); let grant = try ledger.grant(2)
            ledger.cancelRequest()
            try refuses("late proposal after request cancellation") { try ledger.receive(grant,tokens:[103,104]) }
            try refuses("missing native branch fence") { try ledger.branchRetired(branch,nativeWorkCompleted:false,payloadLeasesReleased:true) }
            try refuses("missing payload release") { try ledger.branchRetired(branch,nativeWorkCompleted:true,payloadLeasesReleased:false) }
            try ledger.branchRetired(branch,nativeWorkCompleted:true,payloadLeasesReleased:true)
            try check(!ledger.controlStateRetired, "Branch ACK does not infer target retirement")
            try ledger.targetAborted(window,evaluationCompleted:true,requestStateRetired:true)
            try check(ledger.controlStateRetired && !ledger.canReseed, "Bilateral control retirement")
            groups += 1
            passed.append("strictCancellationRequiresBilateralRetirement")
        }
        do {
            var ledger = try fresh(); let branch = try start(&ledger); try ledger.finishRequest()
            try check(!ledger.controlStateRetired, "Success still requires remote branch retirement")
            try ledger.branchRetired(branch,nativeWorkCompleted:true,payloadLeasesReleased:true)
            try check(ledger.controlStateRetired && ledger.requestCompleted && !ledger.requestCancelled, "Success distinct from request failure")
            groups += 1
            passed.append("strictSuccessRequiresBranchRetirement")
        }
        do {
            for depth in [2,4,8] {
                var ledger = try fresh(depth:depth); _ = try start(&ledger)
                let tokens = Array(101..<(101+depth)); try feed(&ledger,tokens)
                let window = try ledger.beginVerification(draftCount:depth)
                let result = try ledger.resolve(window,targetTokens:tokens+[101+depth]); try commit(&ledger,result)
                try check(ledger.counters.accepted == depth && ledger.counters.committedOutputTokens == depth+1, "Separate accepted versus emitted counts")
            }
            try refuses("unsupported maximum depth") { _ = try fresh(depth:3) }
            groups += 1
            passed.append("strictDepthAndAcceptedOutputCounters")
        }
        do {
            var ledger = try fresh(vocabulary: 64, seed: 10); _ = try start(&ledger)
            let grant = try ledger.grant(2)
            try refuses("caller vocabulary upper bound") { try ledger.receive(grant,tokens:[11,64]) }
            try refuses("negative token") { try ledger.receive(grant,tokens:[11,-1]) }
            try ledger.receive(grant,tokens:[11,63])
            let window = try ledger.beginVerification(draftCount:2)
            try refuses("target vocabulary bound") { _ = try ledger.resolve(window,targetTokens:[11,63,64]) }
            _ = try ledger.resolve(window,targetTokens:[11,63,12])
            try refuses("empty vocabulary") { _ = try fresh(vocabulary:0,seed:0) }
            try refuses("non-Int32 vocabulary") { _ = try fresh(vocabulary:Int(Int32.max)+1,seed:0) }
            try refuses("seed outside caller vocabulary") { _ = try fresh(vocabulary:64,seed:64) }
            groups += 1
            passed.append("strictCallerVocabularyBounds")
        }
        print("PASS \(groups) Foundation proposal-ledger groups; no native, physical or numerical qualification")
        let bytes = try JSONSerialization.data(withJSONObject: ["schema":"gemma4_strict_ledger_labeled_checks_v1", "passed":passed, "nativeExecuted":false, "targetMathQualified":false], options:[.sortedKeys])
        print(String(decoding:bytes,as:UTF8.self))
    }
}
