#if QWEN_TARGET_TINY_FIXTURE
import Foundation
import MLX
import MLXNN

/// Actual fabricated-weight Qwen trunks and shared target-state transactions.
/// No registered checkpoint, assistant proposal, network or provider claim.
@_spi(ClusterTesting) public enum TargetVerificationSessionCheck {
    public static func run() throws -> Data {
        try MLX.withError { native in
            do {
                let deadline = DispatchTime.now().uptimeNanoseconds + 55_000_000_000
                func checked() throws {
                    try native.check()
                    guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ProbeError("Tiny Session fixture expired") }
                }
                weak var first: Module?, last: Module?
                let result = try autoreleasepool { () throws -> Data in
                    let model = try QwenTinyTargetModel.make(check: checked)
                    first = model.stages[0].model; last = model.stages[1].model
                    return try perform(model: model, check: checked)
                }
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
                guard first == nil, last == nil else { throw ProbeError("Tiny stage models remained owned after request cleanup") }
                Memory.clearCache(); try checked()
                return result
            } catch { try native.check(); throw error }
        }
    }

    private static func perform(model: QwenTinyTargetModel, check: @escaping () throws -> Void) throws -> Data {
        let require = QwenTinyTargetAssertions.require
        var passed: [String] = [], maximumDifference: Float = 0
        // Separate fresh ordinary target evaluation supplies a matching scalar
        // for acceptance test inputs; this does not pretend an MTP proposed it.
        let oracle = try QwenTinyTargetCase(model: model, check: check)
        try oracle.prefillAndSelectSeed()
        let seed = oracle.seed
        let draft = try QwenTinyTargetAssertions.token(oracle.ordinary.decode(seed), check: oracle.resources.requireLive)
        let ledger = try JSONSerialization.jsonObject(with: canonicalJSONData(oracle.resources.ledger))
        try oracle.cancel()

        for keep in 0...2 {
            let difference = try autoreleasepool { () throws -> Float in
                let value = try QwenTinyTargetCase(model: model, check: check)
                defer { try? value.cancel() }
                try value.prefillAndSelectSeed(); try require(value.seed == seed, "Tiny source replay selected a different seed")
                let proposal = value.proposal(draft)
                try value.begin(proposal); try value.stage(proposal)
                try value.reconcile(proposal, keeping: keep)
                try value.replayOrdinary(keeping: keep, proposal: proposal)
                // One further real decode proves immediate KV position rebinding
                // and committed recurrent restoration, including keep0.
                let next = keep == 0 ? seed : (draft + 7) % 128
                let a = try value.ordinary.decode(next), b = try value.target.decode(next)
                let difference = try QwenTinyTargetAssertions.logits(a, b, check: value.resources.requireLive)
                try QwenTinyTargetAssertions.state(value.ordinary, value.target)
                try value.cancel()
                return max(value.maximumDifference, difference)
            }
            maximumDifference = max(maximumDifference, difference); passed.append("actual-trunk-keep-\(keep)-and-next-decode")
        }
        try autoreleasepool {
            let value = try QwenTinyTargetCase(model: model, check: check)
            defer { try? value.cancel() }
            try value.prefillAndSelectSeed()
            let proposal = value.proposal((draft+1)%128)
            try value.begin(proposal); try value.stage(proposal)
            try require(value.provisionalTokens[0] != proposal.proposedTokenID, "Mismatch fixture accidentally matched")
            try value.reconcile(proposal, keeping: 1)
            try value.replayOrdinary(keeping: 1, proposal: proposal)
            let a = try value.ordinary.decode(value.provisionalTokens[0]), b = try value.target.decode(value.provisionalTokens[0])
            maximumDifference = max(max(maximumDifference, value.maximumDifference),
                try QwenTinyTargetAssertions.logits(a, b, check: value.resources.requireLive))
            try QwenTinyTargetAssertions.state(value.ordinary, value.target)
            try value.cancel()
        }
        passed.append("actual-mismatching-draft-rollback-and-next-decode")
        for continuing in [false, true] {
            maximumDifference = max(maximumDifference, try progressive(model: model, seed: seed,
                draft: draft, continuing: continuing, outputCount: 4, stops: [], check: check))
            passed.append(continuing ? "actual-progressive-continue" : "actual-progressive-client-stop")
        }
        maximumDifference = max(maximumDifference, try progressive(model: model, seed: seed,
            draft: draft, continuing: false, outputCount: 2, stops: [], check: check))
        passed.append("actual-one-step-output-limit")
        // If the same greedy token occurs twice, making token2 EOS also makes
        // token1 EOS. Record that limitation, never invent a post-seed EOS run.
        if draft != seed {
            maximumDifference = max(maximumDifference, try progressive(model: model, seed: seed,
                draft: draft, continuing: true, outputCount: 4, stops: [draft], check: check))
            passed.append("actual-progressive-eos")
        }
        try failures(model: model, seed: seed, draft: draft, check: check, passed: &passed)
        return try JSONSerialization.data(withJSONObject: ["fixture": "fabricated-full-source-two-real-stages",
            "passed": passed, "maximumLogitDifference": maximumDifference,
            "stateComparison": "exact-named-state-hashes-after-reconcile-and-next-decode",
            "seedTokenID": seed, "ordinaryTargetChosenDraftTokenID": draft,
            "eosAfterSeedExercised": draft != seed, "resourceLedger": ledger,
            "sourceTensorCount": model.sourceTensorCount, "sourceTensorBytes": model.sourceTensorBytes,
            "sourcePayloadSHA256": model.sourcePayloadSHA256,
            "stageActiveTensorCounts": model.stages.map { $0.receipt.activeTensors.count },
            "sharedSessionTransactionExecuted": true, "registeredProfileExecuted": false,
            "mtpAssistantProposalExecuted": false, "bilateralWireVerification": false,
            "providerEligibilityEstablished": false], options: [.sortedKeys])
    }

    private static func progressive(model: QwenTinyTargetModel, seed: Int, draft: Int, continuing: Bool,
        outputCount: Int, stops: Set<Int>, check: @escaping () throws -> Void) throws -> Float {
        try autoreleasepool {
            let value = try QwenTinyTargetCase(model: model, outputCount: outputCount, stops: stops, check: check)
            defer { try? value.cancel() }
            try value.prefillAndSelectSeed()
            try QwenTinyTargetAssertions.require(value.seed == seed, "Tiny source replay seed differs")
            let proposal = value.proposal(draft)
            try value.begin(proposal); try value.stage(proposal)
            try QwenTinyTargetAssertions.require(value.provisionalTokens[0] == draft, "Oracle-selected draft did not match actual seed target")
            try value.commit(proposal, prefix: 1)
            try value.publishCommittedStep(0, continueRequested: continuing)
            var kept = 1
            if value.generation.phase == .frame {
                try value.commit(proposal, prefix: 2)
                try value.publishCommittedStep(1, continueRequested: false)
                kept = 2
            }
            try value.reconcile(proposal, keeping: kept)
            try value.replayOrdinary(keeping: kept, proposal: proposal)
            try QwenTinyTargetAssertions.require(value.generation.committedTokens == 5+kept
                && value.generation.selectedTokenCount == kept+1, "Published and consumed frontiers differ")
            try value.finishTarget(); try value.ordinary.cancel()
            return value.maximumDifference
        }
    }

    private static func failures(model: QwenTinyTargetModel, seed: Int, draft: Int,
        check: @escaping () throws -> Void, passed: inout [String]) throws {
        for kind in ["owner-before-stage", "owner-after-two-stages", "pending-snapshot", "pending-decode", "pending-finish", "commit-then-reject-prefix", "seed-eos"] {
            try autoreleasepool {
                let value = try QwenTinyTargetCase(model: model, stops: kind == "seed-eos" ? [seed] : [], check: check)
                defer { try? value.cancel() }
                try value.prefillAndSelectSeed()
                let proposal = value.proposal(draft), victim = value.target.sessions[0]
                var refused = false
                func acceptExpected(_ error: Error) throws {
                    let wanted: String
                    switch kind {
                    case "owner-before-stage": wanted = "Injected tiny owner refusal"
                    case "owner-after-two-stages": wanted = "Injected refusal after real native staging"
                    case "commit-then-reject-prefix": wanted = "Target verification schedule or retained prefix differs"
                    case "seed-eos": wanted = "Target verification proposal differs from the continued committed token chain"
                    default: wanted = "CBv2 state is retired, failed or has unfinished work"
                    }
                    // A native fault, unrelated resource refusal or failed
                    // cleanup is not an expected negative-test success.
                    guard let value = error as? ProbeError, value.description == wanted else { throw error }
                    refused = true
                }
                if kind == "owner-before-stage" || kind == "seed-eos" {
                    do {
                        _ = try victim.beginTinyTargetVerification(resources: value.resources, proposal: proposal,
                            generation: value.generation, ownerCheck: { _ in
                                if kind == "owner-before-stage" { throw ProbeError("Injected tiny owner refusal") }
                            })
                    } catch { try acceptExpected(error) }
                } else {
                    try value.begin(proposal)
                    if kind == "owner-after-two-stages" || kind == "commit-then-reject-prefix" { try value.stage(proposal) }
                    if kind == "commit-then-reject-prefix" { try value.commit(proposal, prefix: 1) }
                    do {
                        if kind == "owner-after-two-stages" {
                            _ = try victim.commitNextTargetVerification(roundID: proposal.roundID,
                                ownerCheck: { _ in throw ProbeError("Injected refusal after real native staging") })
                        } else if kind == "commit-then-reject-prefix" {
                            _ = try victim.reconcileTargetVerification(roundID: proposal.roundID, keepingInputs: 0,
                                ownerCheck: { _ in try value.resources.requireLive() })
                        } else if kind == "pending-snapshot" {
                            _ = try victim.snapshot(check: value.resources.requireLive)
                        } else if kind == "pending-decode" {
                            _ = try victim.decode(seed, offset: 5, check: value.resources.requireLive)
                        } else {
                            try victim.finishGeneration(.clientStop, selectedTokenCount: 1, lastTokenID: seed)
                        }
                    } catch { try acceptExpected(error) }
                }
                try QwenTinyTargetAssertions.require(refused && victim.isClosed && victim.isFailed,
                    "Tiny invalid operation did not refuse and retire actual native state")
                try value.cancel()
                try QwenTinyTargetAssertions.require(value.target.sessions.allSatisfy(\.isClosed), "Tiny peer request did not retire")
            }
            passed.append("actual-" + kind + "-retired")
        }
    }
}
#endif
