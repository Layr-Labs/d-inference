import Cmlx
import Foundation
import MLX
import MLXLMCommon
@_spi(DarkbloomCluster) import MLXLLM

/// One serialized producer, never Sendable. The enclosing service retains this
/// object after error; only a successful fence permits roots to be dropped.
final class Gemma4MTPPullBatchOwner {
    private let assistant: Gemma4AssistantDraftModel
    private let conditioning: Gemma4MTPConditioning
    private let auxiliary: Gemma4MTPAuxiliaryOwner
    private let producerCreditPolicy: Gemma4MTPProducerCreditPolicy
    private var finalBatchCount: Int?
    private var expectedTokenCount = 0
    private var branch: Gemma4MTPFrozenProposalBranch?
    private var capture: Gemma4OwnedMTPConditioning?
    private var identity: AsyncMTPProposalLedger.BranchID?
    private var pending: Gemma4MTPFrozenProposalBranch.Batch?
    private var submitted = false, completed = false, failed = false

    init(assistant: Gemma4AssistantDraftModel, conditioning: Gemma4MTPConditioning,
         auxiliary: Gemma4MTPAuxiliaryOwner, producerCreditPolicy: Gemma4MTPProducerCreditPolicy = .legacy) throws {
        guard auxiliary.budget.placement == .remoteAssistant,
              auxiliary.budget.maximumDraftTokens == 2, auxiliary.budget.maximumBufferedProposals == 5 else {
            throw ProbeError("Remote MTP batch owner requires the unchanged depth-two auxiliary ledger")
        }
        self.assistant = assistant; self.conditioning = conditioning; self.auxiliary = auxiliary
        self.producerCreditPolicy = producerCreditPolicy
    }
    func install(_ capture: Gemma4OwnedMTPConditioning, id: AsyncMTPProposalLedger.BranchID,
                 check: () throws -> Void) throws {
        guard !failed, branch == nil, pending == nil, identity == nil,
              capture.frontier == id.snapshotFrontier else { throw ProbeError("Remote MTP reseed precedes retirement") }
        try check(); try auxiliary.requireGrant(count:1,capture:capture)
        let row = CBv2MTPRowCapture(fullKeys:capture.fullKeys,fullValues:capture.fullValues,
            slidingKeys:capture.slidingKeys,slidingValues:capture.slidingValues,
            slidingStart:capture.frontier-capture.slidingKeys.dim(2),anchor:capture.frontier)
        self.capture = capture; identity = id
        branch = try Gemma4MTPFrozenProposalBranch(drafter:assistant,conditioning:conditioning,row:row,
            seedToken:id.initialSeedToken,hidden:capture.hidden,
            maximumProposals:auxiliary.budget.maximumFrontier-capture.frontier)
        try check()
    }
    func prepare(_ grant: AsyncMTPProposalLedger.Grant, check: () throws -> Void) throws {
        guard !failed, identity == grant.branch, let branch, let capture, pending == nil,
              grant.firstPosition == branch.anchor+branch.generatedProposals+1 else { throw ProbeError("Remote MTP native grant is stale or already live") }
        let batches = try producerCreditPolicy.nativeBatchCounts(for:grant.count)
        expectedTokenCount = grant.count; finalBatchCount = batches.count == 2 ? batches[1] : nil
        try check(); try auxiliary.requireGrant(count:batches[0],capture:capture)
        pending = try branch.build(grantedCount:batches[0])
        submitted = false; completed = false
        try check()
    }
    /// Called AFTER queued ACK. No P2P call occurs until both stream fences
    /// finish. The target Mac may verify concurrently under its own owner.
    func execute(check: () throws -> Void) throws -> [Int] {
        // All ordinary <=2 credits keep the original execution body unchanged.
        guard expectedTokenCount == 3 else { return try executeSingle(check:check) }
        do {
            guard producerCreditPolicy == .threeForDepthTwo, finalBatchCount == 1,
                  pending?.count == 2, !failed, !submitted, !completed else {
                throw ProbeError("Remote split credit has no exact first batch")
            }
            // Only CPU IDs leave this autorelease scope. The branch deliberately
            // retains its now-evaluated last token/hidden as continuation inputs.
            var tokens = try autoreleasepool { try executeSingle(check:check) }
            guard completed, tokens.count == 2, let branch, let capture else {
                throw ProbeError("Remote first sub-batch did not complete exactly")
            }
            // executeSingle has joined both streams, checked C status, read back
            // IDs, and freed its C vector. Drop its owned concat before build(1).
            pending = nil; submitted = false; completed = false; finalBatchCount = nil
            try check(); try auxiliary.requireGrant(count:1,capture:capture)
            pending = try branch.build(grantedCount:1)
            try check()
            tokens += try autoreleasepool { try executeSingle(check:check) }
            guard completed, tokens.count == expectedTokenCount else {
                throw ProbeError("Remote split result differs from exact credit")
            }
            return tokens
        } catch { failed = true; auxiliary.poison(); throw error }
    }
    private func executeSingle(check: () throws -> Void) throws -> [Int] {
        guard !failed, let pending, !submitted, !completed else { throw ProbeError("Remote MTP batch submission is replayed") }
        do {
            return try MLX.withError { native in
                func checked() throws { try native.check(); try check(); try native.check() }
                try checked(); submitted = true
                let contexts = [pending.tokens.ctx,pending.lastHidden.ctx]
                let vector = contexts.withUnsafeBufferPointer { mlx_vector_array_new_data($0.baseAddress,$0.count) }
                defer { mlx_vector_array_free(vector) }
                let submitStatus = mlx_async_eval(vector)
                // Do not throw/release roots between submission and the fence.
                try Gemma4MTPPullNativeFence.join(check:checked)
                guard submitStatus == 0 else { throw ProbeError("Remote MTP asynchronous submission failed with C status \(submitStatus)") }
                guard pending.tokens.shape == [1,pending.count], pending.tokens.dtype == .int32,
                      pending.lastHidden.shape == [1,1,2816] else { throw ProbeError("Remote MTP evaluated batch geometry differs") }
                let tokens = pending.tokens.asArray(Int32.self).map(Int.init)
                guard tokens.count == pending.count, tokens.allSatisfy({ (0..<262_144).contains($0) }) else { throw ProbeError("Remote MTP proposal readback differs") }
                try checked(); completed = true; return tokens
            }
        } catch { failed = true; auxiliary.poison(); throw error }
    }
    func delivered() throws {
        guard !failed, completed, pending != nil else { throw ProbeError("Remote MTP payload released before completion") }
        pending = nil; submitted = false; completed = false
        finalBatchCount = nil; expectedTokenCount = 0
    }
    func retire(check: () throws -> Void) throws {
        guard !failed else { throw ProbeError("Failed remote MTP native work requires original-owner retirement") }
        try Gemma4MTPPullNativeFence.join(check:check)
        pending = nil; branch = nil; capture = nil; identity = nil
        submitted = false; completed = false
        finalBatchCount = nil; expectedTokenCount = 0
        try check()
    }
    func poison() { failed = true; auxiliary.poison() }
    func unbindAfterRetirement() throws {
        guard !failed, branch == nil, pending == nil, capture == nil, identity == nil else {
            throw ProbeError("Remote MTP unbind precedes branch retirement")
        }
        assistant.unbind()
    }
}
