// Copyright © 2026 Eigen Labs.
//
// Coordinator-serving decisions. `handleInferenceRequest` owns decryption,
// admission, acceptance, model load, the response key and the detached task;
// once it holds the slot it hands a decision body here instead of the chat
// stream. A decision answers in exactly one `inference_response_chunk` (one
// SSE `data:` frame carrying the response JSON) followed by
// `inference_complete` with `prompt_tokens` = Σ question prompt tokens and
// `completion_tokens` = one per question. Logs carry counts only, never the
// state, questions, codes or probabilities.

import Foundation
import MLXLMCommon

extension ProviderLoop {
    /// Everything the decision path borrows from the inference handler's
    /// detached task. The handler keeps ownership of every lifetime here.
    struct DecisionServingContext: Sendable {
        let requestId: String
        let modelId: String
        let request: DecisionRequest
        /// Loaded slot identity (never the caller's model name).
        let modelType: String?
        let container: MLXLMCommon.ModelContainer?
        let makeEngine: DecisionRunner.EngineFactory
        /// Question 0's usage signal; it settles the request's cache receipt.
        let usageSignal: EngineV2RequestUsageSignal
        let reportsCacheUsage: Bool
        let emitFrame: @Sendable (String) -> Bool
        /// Sends the deadline terminal itself and returns true when expired.
        let rejectExpiredDeadline: @Sendable () -> Bool
        let finalizeProfile: @Sendable (Int, Int, Bool, Duration?) -> Void
        let profile: RequestProfileBuilder
        let lookupReceiptFinalizer: PrefixCacheLookupReceiptFinalizer
        let send: SendHandle
        let token: InferenceCancellationToken
        let stats: AtomicProviderStats
        let signer: (any AttestationSigner)?
        let log: ProviderLogger
    }

    /// The per-question engine view: the handler's chat engine construction
    /// with the question's logprobs plumbing and input bound. Only question 0
    /// carries the request's usage signal, which is single-request by
    /// contract; later questions get the engine's own fresh signal.
    /// `promptWork` describes a coordinator-rendered chat prompt; decisions
    /// are rendered here, so none is forwarded.
    static func decisionEngineFactory(
        modelId: String,
        entry: MultiModelBatchSchedulerEngine.ModelRegistryEntry,
        cacheScope: String,
        remoteCache: RemotePrefixCacheContext,
        usageSignal: EngineV2RequestUsageSignal,
        firstContentDeadline: FirstContentDeadline?,
        profile: RequestProfileBuilder,
        serviceReservationID: String?,
        serviceReservation: ServiceReservationLifetime?
    ) -> DecisionRunner.EngineFactory {
        { submission in
            MultiModelBatchSchedulerEngine(
                registryProvider: { [modelId: entry] },
                defaultMaxTokens: ProviderLoop.schedulerDefaultMaxTokens,
                cacheScope: cacheScope,
                cacheEnabled: remoteCache.cacheEnabled,
                donationDemand: remoteCache.donationDemand,
                engineV2Logprobs: submission.logprobs,
                engineV2Usage: submission.index == 0 ? usageSignal : nil,
                decisionInputTokenLimit: submission.inputTokenLimit,
                firstContentDeadline: firstContentDeadline,
                profile: profile,
                serviceReservationID: serviceReservationID,
                serviceReservation: serviceReservation)
        }
    }

    static func serveDecision(_ context: DecisionServingContext, loop: ProviderLoop) async {
        let outcome: DecisionRunner.Outcome
        do {
            let configuration = try await DecisionRunner.configuration(
                modelType: context.modelType, container: context.container)
            outcome = try await DecisionRunner(configuration: configuration, makeEngine: context.makeEngine)
                .run(context.request)
        } catch {
            await sendDecisionFailure(error, context: context, loop: loop)
            return
        }
        if context.token.isCancelled {
            await sendDecisionFailure(CancellationError(), context: context, loop: loop)
            return
        }
        // The answer is the first content: a deadline that expired during the
        // last readout refuses it, exactly as for a chat stream's first frame.
        if context.rejectExpiredDeadline() { return }
        let body = outcome.response.compactJSON
        let frame = "data: \(body)\n\n"
        guard context.emitFrame(frame) else { return }
        context.profile.mark(.firstFrame)

        context.stats.incrementRequestsServed()
        context.stats.addTokensGenerated(UInt64(outcome.outputTokens))
        await loop.updateAggregateCapacity()

        let seSignStart = SuspendingClock.now
        let attestation = computeResponseAttestation(
            identity: context.signer,
            requestId: context.requestId,
            completionTokens: UInt64(outcome.outputTokens),
            responseBody: body)
        let seSignDuration = SuspendingClock.now - seSignStart
        let cacheResult = context.reportsCacheUsage ? context.usageSignal.lookupResult : nil
        let usage = UsageInfo(
            promptTokens: UInt64(max(0, outcome.inputTokens)),
            completionTokens: UInt64(outcome.outputTokens),
            cacheOutcome: cacheResult?.outcome,
            cacheTier: cacheResult?.tier,
            cachedTokens: cacheResult.map { UInt64(max(0, $0.cachedTokens)) },
            prefillTokensSaved: cacheResult.map { UInt64(max(0, $0.prefillTokensSaved)) },
            cacheStageMs: cacheResult?.stageMs)
        context.finalizeProfile(1, frame.utf8.count, false, seSignDuration)
        context.lookupReceiptFinalizer.sendTerminal(
            .inferenceComplete(
                requestId: context.requestId,
                usage: usage,
                stopSequence: nil,
                seSignature: attestation.signature,
                responseHash: attestation.hash,
                profile: context.profile),
            fallbackFailure: .policy,
            send: context.send)
        context.log.info(
            "[\(context.requestId)] Decision complete: \(context.request.questions.count) questions, "
                + "\(outcome.inputTokens) prompt tokens")
    }

    /// Nothing was delivered on any failure path, so the coordinator refunds.
    private static func sendDecisionFailure(
        _ error: Error, context: DecisionServingContext, loop: ProviderLoop
    ) async {
        context.finalizeProfile(0, 0, false, nil)
        let failure: InferenceFailure
        if error is CancellationError || context.token.isCancelled {
            context.log.info("[\(context.requestId)] Decision cancelled before output")
            context.stats.incrementCancellationsBeforeOutput()
            context.profile.mark(.cancelAborted)
            failure = InferenceFailure(code: .cancelled, statusCode: 499, terminalCause: .cancelled)
        } else if let deadline = error as? PreContentDeadlineFailure {
            context.log.info("[\(context.requestId)] Refusing pre-content decision: \(deadline.rawValue)")
            failure = CapacityRejectionEnrichment.enrich(
                sanitizedInferenceFailure(from: deadline, phase: .streamStart),
                modelId: context.modelId,
                published: loop.state.publishedCapacity,
                fallbackReason: .deadline)
        } else {
            let sanitized = sanitizedInferenceFailure(from: error, phase: .streamStart)
            InferenceFailureLogger(logger: context.log).record(
                requestId: context.requestId, failure: sanitized)
            failure = CapacityRejectionEnrichment.enrich(
                sanitized,
                modelId: context.modelId,
                published: loop.state.publishedCapacity,
                fallbackReason: .tokenBudget)
        }
        context.lookupReceiptFinalizer.sendTerminal(
            .inferenceError(requestId: context.requestId, failure: failure, profile: context.profile),
            fallbackFailure: failure.code == .capacity ? .capacity : .policy,
            send: context.send)
    }
}
