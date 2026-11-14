import Foundation
import Logging
import MLXLMCommon

extension EngineV2Bridge {
    private static let turnContinuationLogger = Logger(label: "darkbloom.TurnContinuation")

    /// The idle work one reply may start. A continuation that completes
    /// publishes the canonical positions it prefilled the way a served request
    /// does, to the complete-checkpoint store when the engine has one. One
    /// that runs out of time or is cancelled keeps the positions it finished
    /// in the resident bank only: the store takes nothing from a cancelled
    /// request.
    static let turnContinuationMaximumSeconds = 60.0

    private enum TurnContinuationOutcome: String {
        /// The engine prefilled every token and stopped by itself.
        case completed
        /// The prefix tiers restored less than the turn before it left there,
        /// so the request was refused before any prefill.
        case skipped
        /// Refused at admission, cancelled by an arrival or the time limit, or
        /// failed.
        case ended
    }

    /// Prefill the tokens the next turn of a conversation is known to start
    /// with, after the request that just replied has retired and only while the
    /// Mac is idle. The work is skipped, never queued, when anything else holds
    /// the Mac, and any arrival cancels it.
    ///
    /// The request is hidden: it has no client, its one sampled token is
    /// discarded, and it reads and writes the prefix tiers under the scope of
    /// the request it follows and no other.
    ///
    /// On the complete-checkpoint store it only extends what that request
    /// left there. When the store and the resident tier both restore less
    /// than that request's last position, the hidden request is refused
    /// before any prefill: it would compute and write the turn's own prompt
    /// again, and a request that arrives meanwhile waits for that write.
    ///
    /// - Parameters:
    ///   - sourceRequestID: the request whose reply just ended.
    ///   - source: the prompt that request ran.
    ///   - shared: the tokens every follow-up of the conversation starts with.
    ///   - cacheScope: the cache scope of the source request.
    func continueTurn(
        after sourceRequestID: String, source: [Int], shared: [Int], cacheScope: String
    ) async {
        guard let cells = turnContinuationCells,
            let plan = cells.plan(source: source, shared: shared) else { return }
        // The client's stream ends before the request retires on this actor.
        let sourceID = Self.normalizedRequestId(sourceRequestID)
        await pumpTasks[sourceID]?.value
        await serviceBudget?.waitForRelease(ownerID: serviceOwnerPrefix + ":" + sourceID)
        guard let engine = ownedEngine as? EngineV2, engine.nativeShutdownExecutionContractID == nil,
            nativeTransactionID == nil, canSubmitWithNativeOwner(), !slotPostureClosed,
            !modelCalibration.closed, modelCalibration.task == nil, active.isEmpty,
            pendingSubmissionIDs.isEmpty, calibrationPosturePermitsWork(),
            let serviceBudget else { return }
        let sourceTokens = source.count
        // The hidden request stages from the prefix store and writes to it.
        // Those transfers are device work, which ends an idle session; this
        // one must outlive its own. Any arrival still ends it.
        let task = serviceBudget.idleCalibration.startIfIdle(
            isIdle: { serviceBudget.isIdle }, toleratesPrefixStoreTransfers: true
        ) { [weak self] in
            await self?.runTurnContinuation(plan, sourceTokens: sourceTokens, cacheScope: cacheScope)
        }
        guard let task else { return }
        modelCalibration.task = task
    }

    private func runTurnContinuation(
        _ plan: TurnContinuationPlan, sourceTokens: Int, cacheScope: String
    ) async {
        modelCalibration.interrupted = false
        let tokens = plan.tokens
        let id = "continuation-" + UUID().uuidString
        modelCalibration.requests[id] = ModelCalibrationPolicy.Cell(
            promptTokens: tokens.count, outputTokens: 1, width: 1, warmup: true, continuation: true,
            restoreFloor: plan.restoreFloor)
        let timer = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.turnContinuationMaximumSeconds * 1_000_000_000))
            } catch { return }
            await self?.interruptModelCalibration([id])
        }
        let started = ContinuousClock.now
        // An arrival cancels this session and then waits for it. No event
        // reaches the loop below during prefill, so the handler cancels.
        var outcome = await withTaskCancellationHandler {
            await runTurnContinuationRequest(id, tokens: tokens, cacheScope: cacheScope)
        } onCancel: {
            Task { await self.interruptModelCalibration([id]) }
        }
        timer.cancel()
        let restored = modelCalibration.unrestoredContinuations.removeValue(forKey: id)
        if restored != nil { outcome = .skipped }
        modelCalibration.requests.removeValue(forKey: id)
        modelCalibration.pendingObservations.removeValue(forKey: id)
        modelCalibration.task = nil
        let elapsed = ContinuousClock.now - started
        let elapsedMs = Int(elapsed.components.seconds) * 1000
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        // What first cancelled this session, when anything did: "request" or
        // "device work". The time limit and an admission refusal leave it out.
        let cancelledBy = outcome == .ended ? serviceBudget?.idleCalibration.cancellationSource : nil
        let cancellation = cancelledBy.map { ", session cancelled by \($0)" } ?? ""
        let shortfall = restored.map { ", prefix tiers restored \($0) of \(plan.restoreFloor) tokens" } ?? ""
        // Counts, timing and that label only; never a token or any text.
        Self.turnContinuationLogger.info(
            "Turn continuation \(modelId): \(outcome.rawValue), \(tokens.count) tokens after a \(sourceTokens)-token prompt in \(elapsedMs) ms\(cancellation)\(shortfall)")
    }

    private func runTurnContinuationRequest(
        _ id: String, tokens: [Int], cacheScope: String
    ) async -> TurnContinuationOutcome {
        guard !Task.isCancelled else { return .ended }
        // No seed: a seeded request takes an engine ID derived from its seed
        // and prompt, which a client's request could mint again.
        let request = ChatCompletionRequest(model: modelId, messages: [], temperature: 0, max_tokens: 1)
        let stream = await LocalPrefillProgress.$current.withValue(nil) {
            await MeFirstOwnerRequest.$makeRoom.withValue(nil) {
                await submitTokenized(
                    promptTokens: tokens, request: request, requestId: id,
                    cacheScope: cacheScope, cacheEnabled: true)
            }
        }
        var outcome = TurnContinuationOutcome.ended
        for await event in stream {
            if Task.isCancelled { cancel(requestId: id); break }
            // A cancelled row reports usage with no finish reason, then an error.
            switch event {
            case .info(_, _, _, let finishReason): outcome = finishReason == nil ? .ended : .completed
            case .error: outcome = .ended
            default: break
            }
        }
        if Task.isCancelled { cancel(requestId: id) }
        await pumpTasks[id]?.value
        await serviceBudget?.waitForRelease(ownerID: serviceOwnerPrefix + ":" + id)
        return outcome
    }
}
