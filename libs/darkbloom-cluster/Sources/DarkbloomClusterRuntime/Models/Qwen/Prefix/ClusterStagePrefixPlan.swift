import Foundation
import MLX

/// What the shared prefix plan needs of a MiMo or GLM stage session.
protocol ClusterStagePrefixSession: AnyObject {
    /// This request's prompt-prefix capture; nil when the prefix cache is off
    /// or the plan split no final token.
    var prefixCapture: ClusterStagePrefixCapture? { get set }
    /// Lets go of a session restored for a plan that will not run it.
    func discardRestored(check: () throws -> Void) throws
}

/// The agreed prefix plan of one request and this rank's session for it.
struct ClusterStagePrefixPlanOutcome<Session: ClusterStagePrefixSession> {
    let agreement: QwenLayerStageGenerationAgreement
    let session: Session
    let summary: QwenStagePrefixSummary
}

/// The dense stages' two-exchange prefix plan (`agreeQwenStagePrefixPlan`),
/// for a MiMo or GLM stage, with the same messages, choice and settlement:
///
/// Exchange 1: each rank offers the frontiers it holds for this prompt (its
/// resident entries and its SSD records); both derive the same choice, the
/// deepest frontier both hold, and split the last prompt token off only if
/// both caches are on. Each rank restores that frontier into a new session
/// from its own tier. Exchange 2: both confirm the choice, the key and the
/// restore; unless all agree, both ranks discard what they restored and
/// prefill from zero (restore on both or neither). Both exchanges run whether
/// or not a cache exists, so the two ranks always take the same steps.
///
/// `restored` builds a session from a kept state for the planned request,
/// `fresh` one that prefills from the planned request's first frame;
/// `capture` makes the family's capture for the planned frontiers. `family`
/// names the stage in the log lines.
func agreeClusterStagePrefixPlan<Session: ClusterStagePrefixSession>(family: String, cache: QwenStagePrefixCache?,
    agreement: QwenLayerStageGenerationAgreement, collective: Collective, check: () throws -> Void,
    restored: (QwenLayerStageGenerationRequest, QwenStagePrefixState) throws -> Session,
    fresh: (QwenLayerStageGenerationRequest, QwenLayerStageGenerationAgreement) throws -> Session,
    capture: (Set<Int>) -> ClusterStagePrefixCapture
) throws -> ClusterStagePrefixPlanOutcome<Session> {
    let request = agreement.request, scope = qwenStagePrefixScope(agreement)
    let enabled = cache?.enabled ?? false
    var resident: [Int] = [], onDisk: [Int] = []
    if enabled, let cache {
        resident = cache.frontiers(scope: scope, tokens: request.promptTokenIDs, maximumFrontier: request.promptCount - 1)
        onDisk = cache.disk?.frontiers(scope: scope, tokens: request.promptTokenIDs,
            maximumFrontier: request.promptCount - 1) ?? []
    }
    let offered = Array(Set(resident).union(onDisk).sorted(by: >).prefix(QwenStagePrefixCache.maximumOffered))
    let local = QwenStagePrefixOffer(enabled: enabled, frontiers: offered, onDisk: Set(onDisk).subtracting(resident))
    let record = CollectiveRecordScope.request(.prefixAgreement, requestID: request.requestID,
        agreementFingerprint: agreement.fingerprint, "prefix")
    let peer = QwenStagePrefixOffer(words: try exchangeQwenStagePrefixWords(collective: collective,
        words: local.words, scope: record.part("offer"), check: check), promptCount: request.promptCount)
    let choice = QwenStagePrefixChoice.choose(local: local, peer: peer, promptCount: request.promptCount)
    var restoredSession: Session?
    var key: String?, tier: String?
    var fromDisk: QwenStagePrefixState?, restoredState: QwenStagePrefixState?
    if choice.reusedPrefix > 0, let cache {
        if let state = cache.state(scope: scope, tokens: request.promptTokenIDs, frontier: choice.reusedPrefix) {
            restoredState = state; tier = "resident"
            cache.disk?.touch(scope: scope, tokens: request.promptTokenIDs, frontier: choice.reusedPrefix)
        } else if let disk = cache.disk,
                  let state = try disk.restore(scope: scope, tokens: request.promptTokenIDs,
                      frontier: choice.reusedPrefix, check: check) {
            restoredState = state; fromDisk = state; tier = "ssd"
        }
    }
    if let state = restoredState {
        key = QwenStagePrefixCache.key(scope: scope, tokens: request.promptTokenIDs[0..<choice.reusedPrefix])
        do {
            let planned = try request.planned(reusedPrefix: choice.reusedPrefix, splitFinalToken: choice.splitFinalToken)
            restoredSession = try restored(planned, state)
        } catch {
            // This rank could not restore; the confirmation says so and both
            // ranks prefill from zero. A native fault still surfaces below.
            log("darkbloom-prefix-v1 rank=\(collective.rank) family=\(family) restore-failed frontier=\(choice.reusedPrefix): \(error)")
            restoredSession = nil
            if tier == "ssd" { cache?.disk?.forget(scope: scope, tokens: request.promptTokenIDs, frontier: choice.reusedPrefix) }
        }
        try check()
    }
    let confirmation = QwenStagePrefixConfirmation(choice: choice,
        restored: choice.reusedPrefix == 0 || restoredSession != nil, key: key)
    let peerConfirmation: QwenStagePrefixConfirmation?
    do {
        peerConfirmation = QwenStagePrefixConfirmation(words: try exchangeQwenStagePrefixWords(collective: collective,
            words: confirmation.words, scope: record.part("confirmation"), check: check))
    } catch {
        try? restoredSession?.discardRestored(check: {})
        throw error
    }
    let settled = QwenStagePrefixConfirmation.settle(local: confirmation, peer: peerConfirmation)
    if settled.reusedPrefix != choice.reusedPrefix || restoredSession == nil {
        // Both ranks prefill from zero. A state this rank read from its SSD is
        // still its valid state at that frontier: it stays resident (within
        // the budget) so the next offer finds it in memory (oMLX U#3327).
        let ownRestoreHeld = restoredSession != nil
        try restoredSession?.discardRestored(check: check); restoredSession = nil; tier = nil
        if ownRestoreHeld, let fromDisk, let cache {
            cache.insert(scope: scope, tokens: request.promptTokenIDs, states: [fromDisk], sharedBytes: fromDisk.sharedBytes)
            log("darkbloom-prefix-v1 rank=\(collective.rank) family=\(family) event=restore-kept frontier=\(choice.reusedPrefix) reason=peer_cold")
        }
    } else if let fromDisk, let cache {
        // Both ranks restored the same frontier; a state read from disk becomes
        // resident too, on both ranks alike, so the next repeat is a memory hit.
        cache.insert(scope: scope, tokens: request.promptTokenIDs, states: [fromDisk], sharedBytes: fromDisk.sharedBytes)
    }
    fromDisk = nil; restoredState = nil
    let plannedRequest = try request.planned(reusedPrefix: settled.reusedPrefix, splitFinalToken: settled.splitFinalToken)
    let plannedAgreement = try agreement.planned(plannedRequest)
    let session = try restoredSession ?? fresh(plannedRequest, plannedAgreement)
    if enabled, let cache, settled.splitFinalToken {
        let frontiers = plannedRequest.prefixCaptureFrontiers(stride: cache.stride(chunkSize: request.chunkSize))
        if !frontiers.isEmpty { session.prefixCapture = capture(frontiers) }
    }
    if settled.reusedPrefix > 0 || choice.reusedPrefix > 0 {
        log("darkbloom-prefix-v1 rank=\(collective.rank) family=\(family) agreed=\(choice.reusedPrefix) reused=\(settled.reusedPrefix)"
            + " prompt=\(request.promptCount) tier=\(tier ?? "none") peer_disk=\(peer.onDisk.contains(choice.reusedPrefix))")
    }
    return .init(agreement: plannedAgreement, session: session, summary: .init(
        reusedPromptTokens: settled.reusedPrefix, restoredTier: tier, agreedPromptTokens: choice.reusedPrefix,
        splitFinalToken: settled.splitFinalToken, storedFrontiers: [], cacheEntries: cache?.count ?? 0))
}

/// Before the first frame: this request's capture within what its reservation
/// charged (older entries make room first), and the hook the running check
/// uses to withdraw it. Returns the charge handed to the session.
func beginClusterStagePrefixCapture(cache: QwenStagePrefixCache?, capture: ClusterStagePrefixCapture?) -> Int? {
    guard let cache else { return nil }
    let limit = cache.takeAdmittedCapture()
    guard cache.enabled, let capture else { return limit }
    capture.limitBytes = limit
    capture.maximumFrontiers = cache.frontiersPerPrompt
    cache.makeRoom(forCapture: limit ?? 0)
    cache.beginCapture { [weak capture] in capture?.withdraw() }
    return limit
}

/// After both ranks retired cleanly: only now do this rank's captured
/// frontiers become reusable, resident and (written behind) on its SSD tier.
/// A failed request stores nothing. Returns the stored frontiers. `family`
/// and `skippedKey` name the stage and its skipped frontiers in the log line.
func storeClusterStagePrefix(cache: QwenStagePrefixCache?, capture: ClusterStagePrefixCapture?,
                             agreement: QwenLayerStageGenerationAgreement, rank: Int, captureLimit: Int?,
                             family: String, skippedKey: String) -> [Int] {
    defer { capture?.discard() }
    guard let cache, cache.enabled, let capture else { return [] }
    let states = capture.states()
    let scope = qwenStagePrefixScope(agreement)
    cache.insert(scope: scope, tokens: agreement.request.promptTokenIDs, states: states, sharedBytes: capture.sharedBytes)
    cache.disk?.persist(scope: scope, tokens: agreement.request.promptTokenIDs, states: states,
        blockTokens: cache.stride(chunkSize: agreement.request.chunkSize))
    if let cost = capture.cost { cache.record(cost) }
    log("darkbloom-prefix-v1 rank=\(rank) family=\(family) held_bytes=\(cache.bytesInUse) budget_bytes=\(cache.budgetBytes)"
        + " capture_limit=\(captureLimit.map(String.init) ?? "none") captured_shared=\(capture.sharedBytes)"
        + " captured_own=\(states.reduce(0) { $0 + $1.ownBytes }) capture_withdrawn=\(capture.withdrawn)"
        + " stored=\(states.map { String($0.committedTokens) }.joined(separator: ","))"
        + (capture.skipped.isEmpty ? "" : " \(skippedKey)=\(capture.skipped.map(String.init).joined(separator: ","))"))
    return states.map(\.committedTokens)
}
