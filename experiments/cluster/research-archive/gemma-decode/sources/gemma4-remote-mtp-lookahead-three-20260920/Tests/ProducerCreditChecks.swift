import Foundation

struct CheckFailure: Error { let reason: String }
func require(_ value: @autoclosure () throws -> Bool, _ reason: String) throws {
    guard try value() else { throw CheckFailure(reason:reason) }
}
func refuses(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw CheckFailure(reason:"Unexpected acceptance")
}

/// Actual scalar ledger/mirror/codec, with explicitly simulated completion facts.
/// These controls execute no model, transfer, C API, stream fence or physical owner.
final class Exchange {
    static var scope: AsyncMTPProposalLedger.Scope {
        .init(requestID:UUID(uuidString:"11111111-1111-1111-1111-111111111111")!,
              membershipEpoch:UUID(uuidString:"22222222-2222-2222-2222-222222222222")!,
              targetBuildSHA256:String(repeating:"1",count:64),assistantBuildSHA256:String(repeating:"2",count:64),
              targetArtifactSHA256:String(repeating:"3",count:64),assistantArtifactSHA256:String(repeating:"4",count:64),
              embeddingIdentitySHA256:String(repeating:"5",count:64))
    }
    var ledger: AsyncMTPProposalLedger
    let mirror: Gemma4MTPPullMirror
    let branch: AsyncMTPProposalLedger.BranchID
    var sequence: UInt64 = 1
    init(maximum: Int = 3, frontier: Int = 129, limit: Int = 256) throws {
        let mirror = try Gemma4MTPPullMirror(scope:Self.scope,requestSHA256:String(repeating:"6",count:64),
            inputFrontier:frontier,seed:9,maximumInputFrontier:limit,maximumProducerGrantTokens:maximum)
        var ledger = mirror.ledger
        let hash = Gemma4MTPPullRecord.captureFingerprint(scope:mirror.scopeSHA256,ordinal:0,frontier:frontier,seed:9,hiddenDType:1)
        let branch = try ledger.startBranch(snapshotFrontier:frontier,snapshotSHA256:hash)
        var seed = Gemma4MTPPullRecord(kind:.seed,sequence:0,scopeSHA256:mirror.scopeSHA256,branch:branch)
        seed.frontier=frontier;seed.seed=9;seed.hiddenDType=1
        guard case .install(let actual) = try mirror.accept(seed), actual == branch else { throw CheckFailure(reason:"Seed action") }
        try require(try mirror.response(.seeded) == seed.changingKind(.seeded),"Seed response")
        try mirror.responseSent()
        self.mirror=mirror;self.ledger=ledger;self.branch=branch
    }
    func record(_ kind: Gemma4MTPPullRecord.Kind) -> Gemma4MTPPullRecord {
        .init(kind:kind,sequence:sequence,scopeSHA256:mirror.scopeSHA256,branch:branch)
    }
    func grant(_ count: Int) throws -> AsyncMTPProposalLedger.Grant {
        let grant = try ledger.grant(count)
        var command=record(.credit);command.frontier=ledger.inputFrontier;command.seed=ledger.seedToken
        command.firstPosition=grant.firstPosition;command.count=grant.count
        guard case .generate(let actual)=try mirror.accept(command),actual==grant else { throw CheckFailure(reason:"Credit action") }
        try require(try mirror.response(.queued)==command.changingKind(.queued),"Queued response")
        try mirror.responseSent();sequence += 1
        return grant
    }
    func deliver(_ grant: AsyncMTPProposalLedger.Grant, _ tokens: [Int]) throws {
        try mirror.generationCompleted(grant,tokens:tokens)
        var command=record(.pull);command.firstPosition=grant.firstPosition;command.count=grant.count
        guard case .deliver(let actual)=try mirror.accept(command),actual==tokens else { throw CheckFailure(reason:"Delivery action") }
        let response=try mirror.response(.proposals);var expected=command.changingKind(.proposals);expected.tokens=tokens
        try require(response==expected,"Exact completed response")
        try ledger.receive(grant,tokens:response.tokens);try mirror.responseSent();sequence += 1
    }
    func produce(_ tokens: [Int]) throws { try deliver(grant(tokens.count),tokens) }
    func commit(_ window: AsyncMTPProposalLedger.Window, target: [Int]) throws {
        let resolved=try ledger.resolve(window,targetTokens:target)
        try ledger.commit(resolved,actualCommittedInputFrontier:resolved.nextInputFrontier,targetEvaluationCompleted:true,rejectedSuffixReconciled:true)
        var command=record(.resolve);command.count=window.draftTokens.count;command.windowOrdinal=window.ordinal
        command.frontier=resolved.nextInputFrontier;command.seed=resolved.nextSeedToken;command.accepted=resolved.acceptedDraftTokens;command.tokens=target
        guard case .resolved=try mirror.accept(command) else { throw CheckFailure(reason:"Resolution action") }
        try require(try mirror.response(.resolved)==command.changingKind(.resolved),"Exact resolution ACK")
        try mirror.responseSent();sequence += 1
        try require(ledger.inputFrontier==mirror.ledger.inputFrontier && ledger.seedToken==mirror.ledger.seedToken,
            "Bilateral authoritative frontier")
        try require(ledger.counters.generated==mirror.ledger.counters.generated
            && ledger.counters.offered==mirror.ledger.counters.offered
            && ledger.counters.accepted==mirror.ledger.counters.accepted
            && ledger.counters.committedOutputTokens==mirror.ledger.counters.committedOutputTokens,
            "Bilateral token counters (not callback-order metrics)")
    }
}

@main struct ProducerCreditChecks {
    static func main() throws {
        var labels:[String]=[]
        func check(_ name:String,_ body:()throws->Void)throws { try body();labels.append(name) }
        try check("default_policy_and_native_batches_unchanged") {
            for depth in [1,2] {
                let p=try Gemma4MTPProducerCreditPolicy(explicit:nil,verificationDepth:depth)
                try require(p.maximumProducerGrantTokens==2 && p.scopeComponents.isEmpty,"Default policy")
                try require(try p.nativeBatchCounts(for:2)==[2],"Original native batch")
                try refuses { _=try p.nativeBatchCounts(for:3) }
            }
        }
        try check("explicit_policy_requires_chosen_d2") {
            for text in ["three_for_depth_two_v1","two_proposal_credit_v1","unknown"] {
                try refuses { _=try Gemma4MTPProducerCreditPolicy(explicit:text,verificationDepth:1) }
            }
            let p=try Gemma4MTPProducerCreditPolicy(explicit:"three_for_depth_two_v1",verificationDepth:2)
            try require(p.scopeComponents==["producerCreditPolicy=three_for_depth_two_v1","maximumProducerCredit=3","nativeProducerBatchLimit=2"],"Exact policy scope")
        }
        try check("default_ledger_refuses_credit_three") {
            let e=try Exchange(maximum:2);try e.produce([10,11]);try refuses { _=try e.ledger.grant(3) }
            try require(e.ledger.maximumDraftTokens==2 && e.ledger.maximumBufferedProposals==5,"Original bounds")
        }
        try check("expanded_scalar_credit_keeps_verification_and_buffer_bounds") {
            let e=try Exchange();try e.produce([10,11]);let grant=try e.grant(3)
            try require(grant.count==3 && e.ledger.proposalCredit==0,"Only one outstanding credit")
            try require(e.ledger.maximumDraftTokens==2 && e.ledger.maximumBufferedProposals==5,"Unchanged native/queue bounds")
            try refuses { _=try e.ledger.beginVerification(draftCount:3) }
        }
        try check("two_ready_plus_three_fills_five_exactly") {
            let e=try Exchange();try e.produce([10,11]);try e.produce([12,13,14])
            try require(e.ledger.proposalCredit==0 && e.ledger.counters.generated==5,"Exact five-slot capacity")
            try refuses { _=try e.ledger.grant(1) }
        }
        try check("four_successful_d2_windows_keep_two_ready_without_refill") {
            let e=try Exchange();try e.produce([10,11]);var next=10
            for _ in 0..<4 {
                let window=try e.ledger.beginVerification(draftCount:2)
                try require(window.draftTokens==[next,next+1],"Ready proposal positions")
                try e.produce([next+2,next+3,next+4]);try e.commit(window,target:[next,next+1,next+2]);next += 3
                try require(!e.ledger.requiresBranchRetirement && e.ledger.proposalCredit==3,"Reusable steady branch")
            }
            let window=try e.ledger.beginVerification(draftCount:2)
            try require(window.draftTokens==[22,23] && e.ledger.counters.generated==14,"Fifth window already ready")
        }
        try check("legacy_two_lookahead_proves_one_ready_shortfall") {
            let e=try Exchange(maximum:2);try e.produce([10,11]);let window=try e.ledger.beginVerification(draftCount:2)
            try e.produce([12,13]);try e.commit(window,target:[10,11,12])
            try refuses { _=try e.ledger.beginVerification(draftCount:2) }
        }
        try check("three_credit_plan_is_two_then_one_only") {
            let p=try Gemma4MTPProducerCreditPolicy(explicit:"three_for_depth_two_v1",verificationDepth:2)
            try require(try p.nativeBatchCounts(for:3)==[2,1],"Bounded native sequence")
            for count in [0,4,5] { try refuses { _=try p.nativeBatchCounts(for:count) } }
            for count in [1,2,3] { try require(try p.nativeBatchCounts(for:count).allSatisfy { (1...2).contains($0) },"No native grant three") }
        }
        try check("existing_record_carries_three_and_refuses_four") {
            let e=try Exchange();var value=e.record(.proposals);value.firstPosition=130;value.count=3;value.tokens=[10,11,12]
            try require(try Gemma4MTPPullRecord.decode(value.encode())==value,"Three-token canonical frame")
            value.tokens.append(13);try refuses { _=try value.encode() }
        }
        try check("legacy_mirror_refuses_three_even_if_sender_claims_it") {
            let e=try Exchange(maximum:2);var command=e.record(.credit);command.frontier=129;command.seed=9;command.firstPosition=130;command.count=3
            try refuses { _=try e.mirror.accept(command) }
        }
        try check("partial_two_token_completion_cannot_satisfy_credit_three") {
            let e=try Exchange();let grant=try e.grant(3)
            try refuses { try e.mirror.generationCompleted(grant,tokens:[10,11]) }
            var pull=e.record(.pull);pull.firstPosition=grant.firstPosition;pull.count=3
            try refuses { _=try e.mirror.accept(pull) }
        }
        try check("outstanding_credit_cancellation_keeps_exact_original_retirement") {
            let e=try Exchange();let grant=try e.grant(3);e.ledger.cancelRequest()
            let command=e.record(.cancel);guard case .cancel=try e.mirror.accept(command) else { throw CheckFailure(reason:"Cancel action") }
            try require(try e.mirror.response(.cancelled)==command.changingKind(.cancelled),"Exact cancellation")
            try e.mirror.responseSent();try e.ledger.branchRetired(e.branch,nativeWorkCompleted:true,payloadLeasesReleased:true)
            try require(e.ledger.controlStateRetired && e.mirror.ledger.controlStateRetired,"Bilateral retired state")
            try refuses { try e.ledger.receive(grant,tokens:[10,11,12]) }
        }
        try check("context_tail_reduces_credit_without_widening_frontier") {
            let e=try Exchange(frontier:129,limit:132);try e.produce([10,11])
            try require(e.ledger.proposalCredit==1,"Exact remaining position")
            try refuses { _=try e.ledger.grant(2) };try e.produce([12]);try require(e.ledger.proposalCredit==0,"Tail exhausted")
        }
        try check("replay_of_completed_credit_is_refused") {
            let e=try Exchange();let grant=try e.grant(3);try e.deliver(grant,[10,11,12])
            try refuses { try e.ledger.receive(grant,tokens:[10,11,12]) }
        }
        try check("rejected_draft_still_requires_branch_retirement") {
            let e=try Exchange();try e.produce([10,11]);let window=try e.ledger.beginVerification(draftCount:2)
            try e.produce([12,13,14]);try e.commit(window,target:[99,11,12])
            try require(e.ledger.requiresBranchRetirement && e.ledger.proposalCredit==0,"Rejection closes branch")
            try refuses { _=try e.ledger.startBranch(snapshotFrontier:e.ledger.inputFrontier,snapshotSHA256:String(repeating:"7",count:64)) }
        }
        try check("producer_extension_is_closed_to_depth_two_three_only") {
            for maxDraft in [2,4,8] {
                try refuses { _=try AsyncMTPProposalLedger(scope:Exchange.scope,inputFrontier:129,seedToken:9,maximumDraftTokens:maxDraft,maximumInputFrontier:256,vocabularySize:262144,maximumProducerGrantTokens:5) }
            }
        }
        let out:[String:Any]=["schema":"gemma4_producer_credit_three_foundation_v1","passed":true,"groups":labels,
            "nativeExecuted":false,"physicalCompletionEstablished":false,"maximumDraftTokens":2,"maximumBufferedProposals":5,
            "maximumProducerCredit":3,"maximumNativeBatch":2]
        print(String(data:try JSONSerialization.data(withJSONObject:out,options:[.sortedKeys]),encoding:.utf8)!)
    }
}
