import Foundation
import MLX

/// Target owns all acceptance and publication. This adapter does not create a
/// request owner, alter its schedule or finish/release its physical lease.
final class Gemma4MTPPullTarget {
    struct Verified {
        let window: Gemma4OwnedMTPWindow
        let confirmedTokens: [Int]
        let acceptedDraftTokens: Int
        let requiresReseed: Bool
        let timing: Gemma4RemoteMTPVerificationTiming
    }
    private let channel: Gemma4MTPPullChannel
    private(set) var ledger: AsyncMTPProposalLedger
    private var branch: AsyncMTPProposalLedger.BranchID?
    private var outstanding: AsyncMTPProposalLedger.Grant?
    private var activeWindow: AsyncMTPProposalLedger.Window?
    // Retained until exact seeded ACK or actual original-owner retirement.
    private var pendingCapture: Gemma4OwnedMTPConditioning?
    private var highestProduced: Int
    private var branchOrdinal: UInt64 = 0
    private var failed = false, stopped = false

    init(channel: Gemma4MTPPullChannel, scope: AsyncMTPProposalLedger.Scope, requestSHA256: String,
         initialFrontier: Int, initialSeed: Int, maximumInputFrontier: Int,
         bonusContinuationPolicy: AsyncMTPBonusContinuationPolicy = .strict) throws {
        let mirror = try Gemma4MTPPullMirror(scope:scope,requestSHA256:requestSHA256,
            inputFrontier:initialFrontier,seed:initialSeed,maximumInputFrontier:maximumInputFrontier,
            bonusContinuationPolicy:bonusContinuationPolicy)
        guard channel.role == .target, channel.scopeSHA256 == mirror.scopeSHA256 else {
            throw ProbeError("Remote MTP target channel differs from the original request")
        }
        self.channel = channel; ledger = mirror.ledger; highestProduced = initialFrontier
    }

    /// The caller supplies an ACTUALLY reconciled window from this same session.
    /// No capture bytes or native admission are inferred from a header/hash.
    func reseed(after window: Gemma4OwnedMTPWindow, session: Gemma4OwnedForwardSession,
                admitSend: (Gemma4MTPPullTransferPlan) throws -> Void,
                check: () throws -> Void) throws {
        do {
            try requireActive()
            guard ledger.canReseed, branch == nil, outstanding == nil, pendingCapture == nil,
                  session.committedTokens == ledger.inputFrontier else { throw ProbeError("Remote MTP reseed precedes exact branch retirement/frontier") }
            let capture = try session.mtpConditioning(after:window,check:check)
            let dtype = try Gemma4MTPPullSnapshot.typeCode(capture.hidden.dtype)
            let plan = try Gemma4MTPPullTransferPlan(frontier:capture.frontier,hiddenDType:dtype)
            try admitSend(plan); try check()
            let identity = Gemma4MTPPullRecord.captureFingerprint(scope:channel.scopeSHA256,
                ordinal:branchOrdinal,frontier:ledger.inputFrontier,seed:ledger.seedToken,hiddenDType:dtype)
            let id = try ledger.startBranch(snapshotFrontier:capture.frontier,snapshotSHA256:identity)
            guard id.ordinal == branchOrdinal else { throw ProbeError("Remote MTP branch ordinal differs") }
            branch = id; highestProduced = capture.frontier
            var command = record(.seed,branch:id)
            command.frontier = ledger.inputFrontier; command.seed = ledger.seedToken; command.hiddenDType = dtype
            pendingCapture = capture
            let response = try withExtendedLifetime(capture) {
                try channel.exchange(command,expecting:.seeded,transfer:{
                    try Gemma4MTPPullSnapshot.send(capture,through:self.channel,plan:plan,check:check)
                },check:check)
            }
            try requireReply(response,command.changingKind(.seeded))
            pendingCapture = nil
            branchOrdinal += 1
        } catch { failed = true; throw error }
    }

    /// Refill synchronously when the prior bridge leaves fewer than k proposals.
    /// Every grant still counts against the same immutable five-slot ledger.
    func fill(draftCount: Int, check: () throws -> Void) throws {
        do {
            try requireActive()
            guard (1...2).contains(draftCount), !ledger.requiresBranchRetirement else { throw ProbeError("Remote MTP fill requires a usable branch") }
            while highestProduced - ledger.inputFrontier < draftCount {
                try grant(min(2,ledger.proposalCredit),check:check)
                try pull(check:check)
            }
        } catch { failed = true; throw error }
    }

    /// Submit lookahead credit BEFORE the real target forward. Its queued ACK
    /// allows the assistant Mac to compute while this Mac verifies width<=3.
    /// Return publishable tokens only after real reconcile AND matching peer ACK.
    func verify(draftCount: Int, session: Gemma4OwnedForwardSession,
                admitVerification: (CBv2AttentionVerificationPlan) throws -> Void,
                denseProjection: Gemma4MTPDenseProjection? = nil,
                check: () throws -> Void) throws -> Verified {
        do {
            return try MLX.withError { native in
                func checked() throws { try native.check(); try check(); try native.check() }
                try requireActive(); try checked()
                guard let branch, outstanding == nil, session.committedTokens == ledger.inputFrontier else {
                    throw ProbeError("Remote MTP verification has no current committed target")
                }
                let selected = try ledger.beginVerification(draftCount:draftCount)
                activeWindow = selected
                let grantStart = DispatchTime.now().uptimeNanoseconds
                if ledger.proposalCredit > 0 { try grant(min(2,ledger.proposalCredit),check:checked) }
                let targetStart = DispatchTime.now().uptimeNanoseconds
                let actual = try session.evaluateMTPInputs([selected.seedToken]+selected.draftTokens,
                    offset:selected.seedPosition,denseProjection:denseProjection,admit:admitVerification,check:checked)
                let selectionStart = DispatchTime.now().uptimeNanoseconds
                guard actual.logits.shape == [1,draftCount+1,262_144] else { throw ProbeError("Remote MTP actual target column geometry differs") }
                let argmax = argMax(actual.logits,axis:-1), finite = all(isFinite(actual.logits))
                eval(argmax,finite); try Gemma4MTPPullNativeFence.join(check:checked)
                guard finite.item(Bool.self), argmax.dtype == .uint32 else { throw ProbeError("Remote MTP target logits are nonfinite or unsupported") }
                let targetTokens = argmax.asArray(UInt32.self).map(Int.init)
                // Drain the granted work even on rejection. Its native/payload
                // roots cannot disappear because the target already knows k.
                let drainStart = DispatchTime.now().uptimeNanoseconds
                if outstanding != nil { try pull(check:checked) }
                let reconcileStart = DispatchTime.now().uptimeNanoseconds
                let resolution = try ledger.resolve(selected,targetTokens:targetTokens)
                let frontier = try session.reconcileMTP(actual,keeping:resolution.acceptedDraftTokens+1,check:checked)
                try checked()
                try ledger.commit(resolution,actualCommittedInputFrontier:frontier,
                    targetEvaluationCompleted:true,rejectedSuffixReconciled:true)
                activeWindow = nil
                let resolutionStart = DispatchTime.now().uptimeNanoseconds
                var command = record(.resolve,branch:branch)
                command.count = draftCount; command.windowOrdinal = selected.ordinal
                command.frontier = frontier; command.seed = resolution.nextSeedToken
                command.accepted = resolution.acceptedDraftTokens; command.tokens = targetTokens
                let response = try channel.exchange(command,expecting:.resolved,check:checked)
                try requireReply(response,command.changingKind(.resolved))
                return .init(window:actual,confirmedTokens:resolution.targetConfirmedTokens,
                    acceptedDraftTokens:resolution.acceptedDraftTokens,requiresReseed:ledger.requiresBranchRetirement,
                    timing:.init(lookaheadGrantNanoseconds:targetStart-grantStart,
                        targetNanoseconds:selectionStart-targetStart,selectionNanoseconds:drainStart-selectionStart,
                        proposalDrainNanoseconds:reconcileStart-drainStart,reconcileNanoseconds:resolutionStart-reconcileStart,
                        resolutionACKNanoseconds:DispatchTime.now().uptimeNanoseconds-resolutionStart))
            }
        } catch { failed = true; throw error }
    }

    func retireRejectedBranch(check: () throws -> Void) throws {
        do {
            try requireActive()
            guard let branch, ledger.requiresBranchRetirement, outstanding == nil, activeWindow == nil else {
                throw ProbeError("Remote MTP branch cannot be replaced while work remains")
            }
            let command = record(.retire,branch:branch)
            let response = try channel.exchange(command,expecting:.retired,check:check)
            try requireReply(response,command.changingKind(.retired))
            // The matching worker produced this only after its actual fence and
            // root release. It is branch retirement, not process/lease release.
            try ledger.branchRetired(branch,nativeWorkCompleted:true,payloadLeasesReleased:true)
            self.branch = nil
        } catch { failed = true; throw error }
    }

    /// May precede a final ordinary target-only seed step when one output remains.
    /// It finishes only the auxiliary protocol; the original target owner stays open.
    func finish(check: () throws -> Void) throws {
        do {
            try requireActive()
            guard let branch, activeWindow == nil else { throw ProbeError("Remote MTP finish has unresolved target work") }
            try ledger.finishRequest()
            let command = record(.finish,branch:branch)
            let response = try channel.exchange(command,expecting:.finished,check:check)
            try requireReply(response,command.changingKind(.finished))
            try ledger.branchRetired(branch,nativeWorkCompleted:true,payloadLeasesReleased:true)
            outstanding = nil; self.branch = nil; stopped = true
        } catch { failed = true; throw error }
    }

    /// Cooperative cancellation requires actual target retirement first. If a
    /// resource/deadline/transport fault prevents this exchange, no ACK/reuse is
    /// inferred; the original bounded parent must retire both native owners.
    func cancel(session: Gemma4OwnedForwardSession, check: () throws -> Void) throws {
        guard !stopped else { throw ProbeError("Remote MTP request is already retired") }
        ledger.cancelRequest()
        try session.cancel()
        // The session may already be closed. Check both actual stream statuses
        // again before releasing any failed transfer loan; no early-close inference.
        try Gemma4MTPPullNativeFence.join(check:check)
        pendingCapture = nil
        if let activeWindow {
            try ledger.targetAborted(activeWindow,evaluationCompleted:true,requestStateRetired:true)
            self.activeWindow = nil
        }
        guard let branch else { stopped = true; return }
        let command = record(.cancel,branch:branch)
        let response = try channel.exchange(command,expecting:.cancelled,check:check)
        try requireReply(response,command.changingKind(.cancelled))
        try ledger.branchRetired(branch,nativeWorkCompleted:true,payloadLeasesReleased:true)
        outstanding = nil; self.branch = nil; stopped = true
    }
    private func grant(_ count: Int, check: () throws -> Void) throws {
        let value = try ledger.grant(count)
        outstanding = value
        var command = record(.credit,branch:value.branch)
        command.frontier = ledger.inputFrontier; command.seed = ledger.seedToken
        command.firstPosition = value.firstPosition; command.count = value.count
        let response = try channel.exchange(command,expecting:.queued,check:check)
        try requireReply(response,command.changingKind(.queued))
    }
    private func pull(check: () throws -> Void) throws {
        guard let outstanding else { throw ProbeError("Remote MTP pull has no credit") }
        var command = record(.pull,branch:outstanding.branch)
        command.firstPosition = outstanding.firstPosition; command.count = outstanding.count
        let response = try channel.exchange(command,expecting:.proposals,check:check)
        var expected = command.changingKind(.proposals); expected.tokens = response.tokens
        try requireReply(response,expected)
        try ledger.receive(outstanding,tokens:response.tokens)
        highestProduced = outstanding.firstPosition+outstanding.count-1
        self.outstanding = nil
    }
    private func record(_ kind: Gemma4MTPPullRecord.Kind, branch: AsyncMTPProposalLedger.BranchID) -> Gemma4MTPPullRecord {
        .init(kind:kind,sequence:channel.sequence,scopeSHA256:channel.scopeSHA256,branch:branch)
    }
    private func requireReply(_ value: Gemma4MTPPullRecord, _ expected: Gemma4MTPPullRecord) throws {
        guard value == expected else { throw ProbeError("Remote MTP reply fields were replayed or substituted") }
    }
    private func requireActive() throws {
        guard !failed, !stopped else { throw ProbeError("Remote MTP target is stopped or failed") }
    }
}
