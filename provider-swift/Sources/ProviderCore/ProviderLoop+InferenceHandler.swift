/// ProviderLoop -- inference request handling.
///
/// Decrypts an inbound request, admits/loads its model, spins up the
/// per-request detached streaming task, and relays encrypted SSE frames back
/// through the coordinator. Includes the update-draining admission gates.

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXVLM
#if canImport(os)
import os
#endif

extension ProviderLoop {
    // MARK: - Inference Request Handling

    /// Whether the provider is draining for a hot-swap update and must refuse
    /// new work. 503 is the documented no-fault reroute signal (the coordinator
    /// routes elsewhere); local requests get a 503-equivalent queue-full. We
    /// only drain AFTER the new bundle is staged and verified (`.installing`
    /// still serves, and staging never touches the live layout), so this never
    /// costs capacity for a failed update.
    ///
    /// Both admission paths call this twice: a fast-path reject up front, and an
    /// authoritative re-check right before the request is registered/reserved —
    /// the early gate is stale across the `await` between them. Each helper is
    /// synchronous + actor-isolated, so the authoritative call is atomic with the
    /// registration that follows (no suspension in between).
    internal var isDrainingForUpdate: Bool { updatePhase == .draining }

    /// Coordinator admission: sends the 503 reroute and returns true if the
    /// request must be dropped because we're draining — for the update
    /// hot-swap, or across the post-retirement reconnect (the socket is
    /// about to close; admitting now would only hand the request to the
    /// `.disconnected` cancel).
    private func rejectIfDrainingForUpdate(
        requestId: String,
        send: SendHandle,
        lookupReceiptFinalizer: PrefixCacheLookupReceiptFinalizer
    ) -> Bool {
        guard isDrainingForUpdate || isReconnectingAfterRetirement else { return false }
        lookupReceiptFinalizer.sendTerminal(
            .inferenceError(
                requestId: requestId,
                failure: CapacityRejectionEnrichment.enrich(
                    InferenceFailure(code: .capacity, statusCode: 503),
                    modelId: nil,
                    published: state.publishedCapacity,
                    fallbackReason: .slotState),
                profile: inflightProfiles[requestId]),
            fallbackFailure: .capacity,
            send: send)
        return true
    }

    /// Preserve the retryable capacity/status compatibility contract while
    /// carrying the typed deadline reason to coordinators that understand it.
    private static func inferenceFailure(
        for failure: PreContentDeadlineFailure
    ) -> InferenceFailure {
        sanitizedInferenceFailure(from: failure, phase: .streamStart)
    }

    /// Reject before `inference_accepted` while the request still owns only its
    /// receipt finalizer. The finalizer settles lookup exactly once.
    private func rejectIfFirstContentDeadlineExpired(
        _ deadline: FirstContentDeadline?,
        requestId: String,
        send: SendHandle,
        lookupReceiptFinalizer: PrefixCacheLookupReceiptFinalizer
    ) -> Bool {
        guard let deadline else { return false }
        do {
            try deadline.check()
            return false
        } catch let failure as PreContentDeadlineFailure {
            lookupReceiptFinalizer.sendTerminal(
                .inferenceError(
                    requestId: requestId,
                    failure: CapacityRejectionEnrichment.enrich(
                        Self.inferenceFailure(for: failure),
                        modelId: nil,
                        published: state.publishedCapacity,
                        fallbackReason: .deadline),
                    profile: inflightProfiles[requestId]),
                fallbackFailure: .capacity,
                send: send)
            return true
        } catch {
            return false
        }
    }

    /// Reject after acceptance and unwind every provider-owned reservation.
    private func rejectAcceptedRequestIfFirstContentDeadlineExpired(
        _ deadline: FirstContentDeadline?,
        requestId: String,
        send: SendHandle,
        lookupReceiptFinalizer: PrefixCacheLookupReceiptFinalizer
    ) async -> Bool {
        guard rejectIfFirstContentDeadlineExpired(
            deadline,
            requestId: requestId,
            send: send,
            lookupReceiptFinalizer: lookupReceiptFinalizer)
        else {
            return false
        }
        if requestToModel.removeValue(forKey: requestId) != nil {
            powerAssertion.release()
            syncWarmModelState()
            await updateAggregateCapacity()
        }
        await cancellationRegistry.finish(requestId: requestId)
        return true
    }

    /// Local-endpoint admission: throws a 503-equivalent when new local work
    /// must be refused — during the update drain (hot-swap restart imminent)
    /// or once the provider is shutting down. The shutdown drain waits on
    /// `localReservations`; without the shutdown gate a steady local client
    /// could keep reservations non-empty and hold `run()` open for the full
    /// shutdown drain timeout, then have its models unloaded mid-stream.
    internal func throwIfRefusingNewLocalWork() throws {
        if isShuttingDown {
            throw MultiModelBatchSchedulerEngineError.queueFull("provider shutting down")
        }
        if isDrainingForUpdate {
            throw MultiModelBatchSchedulerEngineError.queueFull(providerDrainingForUpdateReason)
        }
    }

    /// Coordinator prefetch/load control messages are not user requests, but
    /// starting new model work during the final update drain is pointless and
    /// can briefly make the coordinator believe a soon-to-restart provider has
    /// warmed a model. Reject them explicitly with the well-known draining
    /// reason — the coordinator treats that load failure as transient (short
    /// backoff) instead of a real load-failure cooldown. The post-restart
    /// registration receives fresh `desired_models` and demand-driven
    /// `load_model` can retry.
    internal func sendDrainingLoadModelFailure(modelId: String, send: SendHandle) {
        send.send(.loadModelStatus(
            modelId: modelId,
            status: .failed,
            error: providerDrainingForUpdateReason
        ))
    }

    internal func sendDrainingPrefetchFailure(modelId: String, send: SendHandle) {
        send.send(.prefetchModelStatus(
            modelId: modelId,
            status: .failed,
            bytesDone: 0,
            bytesTotal: 0,
            error: providerDrainingForUpdateReason
        ))
    }

    internal func handleInferenceRequest(
        requestId: String,
        ciphertext: Data,
        senderPublicKey: Data?,
        cacheReceiptNonce: String?,
        authenticatedCacheScope: String?,
        prefixCacheProtocol: Int? = nil,
        toolSchemaMetadataProtocol: Int? = nil,
        firstContentDeadline: FirstContentDeadline? = nil,
        receivedAt: ContinuousClock.Instant = .now,
        profile requestProfile: RequestProfileBuilder? = nil,
        send: SendHandle
    ) async {
        // Profiler accumulator anchored at frame receipt (a fresh one for
        // direct/test callers). Registered so `handleCancellation` can stamp
        // cancel receipt; removed on every exit that does not hand it to the
        // detached task (see the `receiptTransferredToTask` defer below).
        let profile = requestProfile ?? RequestProfileBuilder()
        let statsForProfileHook = self.stats
        profile.update { f, now in
            f.mark(.dequeued, offsetUs: now)
            // `tokens_after_cancel_total` is bumped by the bridge at engine
            // finish, which on the cancel path can run AFTER this request's
            // terminal already went out (the cancelled terminal is built
            // before the engine's `.finished(.cancelled)`), so the detached
            // task's defer cannot own that add.
            // Captures ONLY the process-lifetime stats sink — never `self`,
            // the profile, or `inflightProfiles` — so the counter lands even
            // when `finishInflightRequest` already dropped the map entry.
            f.onTokensAfterCancel = { tokens in
                statsForProfileHook.addTokensAfterCancel(UInt64(max(0, tokens)))
            }
        }
        inflightProfiles[requestId] = profile
        logger.info("Processing inference request: \(requestId)")

        // Cache receipt ownership begins before any admission/decrypt/load work.
        // A valid nonce must settle exactly once even when the request never
        // reaches EngineV2Bridge.submitTokenized.
        let remoteCache = RemotePrefixCacheContext(
            cacheScope: authenticatedCacheScope,
            cacheReceiptNonce: cacheReceiptNonce)
        var receiptCallbacks: (
            lookup: (@Sendable (PrefixCacheLookupResult) -> Void)?,
            ready: (@Sendable (PrefixCacheReadyResult) -> Void)?
        ) = (nil, nil)
        if prefixCacheProtocol != 2 {
            receiptCallbacks = PrefixCacheReceiptEmitter.callbacks(
                requestID: requestId,
                nonce: remoteCache.receiptNonce,
                send: send)
        }
        let lookupReceiptFinalizer = PrefixCacheLookupReceiptFinalizer(
            callback: receiptCallbacks.lookup)
        var receiptTransferredToTask = false
        defer {
            if !receiptTransferredToTask {
                lookupReceiptFinalizer.finalize(failure: .policy)
                inflightProfiles.removeValue(forKey: requestId)
            }
        }

        if rejectIfFirstContentDeadlineExpired(
            firstContentDeadline,
            requestId: requestId,
            send: send,
            lookupReceiptFinalizer: lookupReceiptFinalizer)
        {
            return
        }

        if isShuttingDown {
            lookupReceiptFinalizer.sendTerminal(
                .inferenceError(
                    requestId: requestId,
                    failure: CapacityRejectionEnrichment.enrich(
                        InferenceFailure(code: .capacity, statusCode: 503),
                        modelId: nil,
                        published: state.publishedCapacity,
                        fallbackReason: .slotState),
                    profile: profile),
                fallbackFailure: .capacity,
                send: send)
            return
        }

        // Fast-path drain reject (skips decrypt/parse work). Re-checked
        // authoritatively at step 4. See `rejectIfDrainingForUpdate`.
        if rejectIfDrainingForUpdate(
            requestId: requestId,
            send: send,
            lookupReceiptFinalizer: lookupReceiptFinalizer)
        {
            return
        }

        // 1. Decrypt the request body. Both `ciphertext` and
        // `senderPublicKey` are already base64-decoded by CoordinatorClient,
        // so we hand the raw bytes straight to NodeKeyPair.decrypt.
        guard let senderKey = senderPublicKey, senderKey.count == 32 else {
            logger.error("[\(requestId)] missing or malformed sender public key")
            lookupReceiptFinalizer.sendTerminal(
                .inferenceError(
                    requestId: requestId,
                    failure: InferenceFailure(code: .invalidRequest, statusCode: 400),
                    profile: profile),
                fallbackFailure: .policy,
                send: send)
            return
        }

        let decryptedData: Data
        do {
            decryptedData = try keyPair.decrypt(
                senderPublicKey: senderKey,
                ciphertext: ciphertext
            )
        } catch {
            logger.error("[\(requestId)] request decryption failed")
            lookupReceiptFinalizer.sendTerminal(
                .inferenceError(
                    requestId: requestId,
                    failure: InferenceFailure(code: .invalidRequest, statusCode: 400),
                    profile: profile),
                fallbackFailure: .policy,
                send: send)
            return
        }
        profile.mark(.decrypted)

        if rejectIfFirstContentDeadlineExpired(
            firstContentDeadline,
            requestId: requestId,
            send: send,
            lookupReceiptFinalizer: lookupReceiptFinalizer)
        {
            return
        }

        if toolSchemaMetadataProtocol != ToolSchemaNormalization.metadataProtocolVersion,
            ToolSchemaNormalization.containsReservedMetadata(in: decryptedData)
        {
            logger.warning(
                "[\(requestId)] rejecting unauthenticated internal tool-schema metadata")
            lookupReceiptFinalizer.sendTerminal(
                .inferenceError(
                    requestId: requestId,
                    failure: InferenceFailure(code: .invalidRequest, statusCode: 400),
                    profile: profile),
                fallbackFailure: .policy,
                send: send)
            return
        }

        if rejectIfFirstContentDeadlineExpired(
            firstContentDeadline,
            requestId: requestId,
            send: send,
            lookupReceiptFinalizer: lookupReceiptFinalizer)
        {
            return
        }

        // 2. Parse the chat completion request into the upstream
        // `OpenAIChatCompletionRequest` shape. `decodeOpenAIRequest`
        // strict-decodes on the fast path and, on failure, normalises a
        // few valid-but-strictly-rejected OpenAI shapes (hosted/custom
        // tools, content-less messages, the `developer` role) before
        // retrying — surfacing the real decoder error on failure rather
        // than a masked one (#252). See ProviderLoop+InboundDecode.swift.
        let chatRequest: OpenAIChatCompletionRequest
        do {
            chatRequest = try Self.decodeOpenAIRequest(decryptedData)
        } catch {
            // Privacy: the provider logger renders the whole message `.public`, and
            // reports collect this subsystem — so never interpolate the raw decode
            // error, which on a malformed body can carry a fragment of the (now
            // decrypted) request, i.e. user prompt content. Log only the error TYPE.
            // The requester-facing string below is likewise kept generic: it transits
            // the coordinator in plaintext and is logged server-side, so interpolating
            // the raw error could resurface a prompt fragment in coordinator logs
            // (defense-in-depth for the "coordinator never sees plaintext" invariant).
            logger.error("[\(requestId)] failed to parse chat request")
            lookupReceiptFinalizer.sendTerminal(
                .inferenceError(
                    requestId: requestId,
                    failure: InferenceFailure(code: .invalidRequest, statusCode: 400),
                    profile: profile),
                fallbackFailure: .policy,
                send: send)
            return
        }
        profile.mark(.parsed)

        if rejectIfFirstContentDeadlineExpired(
            firstContentDeadline,
            requestId: requestId,
            send: send,
            lookupReceiptFinalizer: lookupReceiptFinalizer)
        {
            return
        }

        // Recover the one out-of-band template-control value once from the
        // authenticated plaintext body. The same value is used by text,
        // vision, and both prompt-token recount paths.
        let templateControls = Self.extractChatTemplateControls(from: decryptedData)
        // Cache identity is coordinator-authored and authenticated outside the
        // sealed OpenAI body. Never trust caller-controlled prompt_cache_key/user
        // for remote cache partitioning. Legacy coordinators omit the outer
        // scope; those requests still serve, but with caching disabled.
        let cacheScope = remoteCache.scope ?? ""
        // OpenAI `logprobs` / `top_logprobs` (also absent from the upstream
        // request shape). Non-nil only when the request asked for logprobs;
        // honored by the EngineV2 path (see EngineV2Logprobs.swift).
        let logprobsSpec = Self.extractLogprobsSpec(from: decryptedData)
        // OpenAI `logit_bias` / `seed` (also absent from the upstream request
        // shape). Overlaid onto the EngineV2 translation.
        let samplingOverrides = Self.extractSamplingOverrides(from: decryptedData)

        if rejectIfFirstContentDeadlineExpired(
            firstContentDeadline,
            requestId: requestId,
            send: send,
            lookupReceiptFinalizer: lookupReceiptFinalizer)
        {
            return
        }

        // 3. Fast pre-accept admission check. The coordinator accepts fast and
        // then waits for the first chunk with the full inference timeout, so we
        // must REJECT (status 503) any request we are *certain* we cannot serve
        // — letting the coordinator reroute — rather than accept-then-fail,
        // which it counts as a provider fault (reputation penalty). This mirrors
        // the real load-failure conditions WITHOUT loading anything and is
        // deliberately conservative: when in doubt it admits and lets the
        // post-accept load path below make the final call.
        let modelId = chatRequest.model
        // Warm/cold classification for the TTFT tracker, captured BEFORE the
        // load step: a cold sample includes model-load latency and must never
        // calibrate warm quotes.
        let modelWasResidentAtDispatch = modelSlots[modelId] != nil
        let fastAdmissionRejected = await fastAdmissionReject(modelId: modelId)
        profile.mark(.admission)
        if rejectIfFirstContentDeadlineExpired(
            firstContentDeadline,
            requestId: requestId,
            send: send,
            lookupReceiptFinalizer: lookupReceiptFinalizer)
        {
            return
        }
        if fastAdmissionRejected {
            // modelId comes from decrypted request JSON. Never reflect it into
            // persistent diagnostics, even though normal callers use catalog IDs.
            logger.warning("[\(requestId)] Pre-accept reject: insufficient capacity to load requested model")
            lookupReceiptFinalizer.sendTerminal(
                .inferenceError(
                    requestId: requestId,
                    failure: CapacityRejectionEnrichment.enrich(
                        InferenceFailure(code: .capacity, statusCode: 503),
                        modelId: modelId,
                        published: state.publishedCapacity,
                        fallbackReason: isRefusedByRetirement(modelId) ? .slotState : .memoryCap),
                    profile: profile),
                fallbackFailure: .capacity,
                send: send)
            return
        }

        // 4. Authoritative drain re-check. `await fastAdmissionReject` above is a
        // suspension point, so draining could have begun (and the drain snapshot
        // taken) while this request was parked — letting it slip past the early
        // gate. There is NO `await` between this check and the `requestToModel`
        // registration below, so on the actor it is atomic: either we reject now,
        // or the request is counted in `hasInflightWork` before any drain
        // snapshot can miss it.
        if rejectIfDrainingForUpdate(
            requestId: requestId,
            send: send,
            lookupReceiptFinalizer: lookupReceiptFinalizer)
        {
            return
        }

        if rejectIfFirstContentDeadlineExpired(
            firstContentDeadline,
            requestId: requestId,
            send: send,
            lookupReceiptFinalizer: lookupReceiptFinalizer)
        {
            return
        }

        // 5. Send inference_accepted
        send.send(.inferenceAccepted(requestId: requestId))
        profile.mark(.acceptedSent)

        // 6. Mark the request before loading so concurrent preloads cannot
        // evict the model this accepted request is waiting for.
        requestToModel[requestId] = modelId
        powerAssertion.acquire()
        syncWarmModelState()
        let token = await cancellationRegistry.register(requestId: requestId)
        guard requestToModel[requestId] == modelId else {
            await cancellationRegistry.finish(requestId: requestId)
            logger.info("[\(requestId)] Request cancelled during admission")
            return
        }
        if await rejectAcceptedRequestIfFirstContentDeadlineExpired(
            firstContentDeadline,
            requestId: requestId,
            send: send,
            lookupReceiptFinalizer: lookupReceiptFinalizer)
        {
            return
        }

        // 6. Ensure model is loaded. The fast check above only rules out
        // certain failures; this stays authoritative for races (e.g. another
        // request consuming the last slot or free memory between accept and
        // load). Map the failure to a status code so capacity errors reroute
        // (503) and missing models 404 instead of always counting as a fault.
        // Profiler: these two reads are, with no `await` in between, exactly
        // the first checks `ensureModelLoaded` performs — the warm return
        // (resident slot) and the park behind another request's in-flight
        // load — so the flags are read here without changing its signature.
        let loadWasWarm = modelSlots[modelId] != nil
        let loadParked = !loadWasWarm && modelsLoading.contains(modelId)
        profile.update { f, now in
            f.mark(.loadWaitStart, offsetUs: now)
            f.set(.loadCold, !loadWasWarm)
            f.set(.loadParked, loadParked)
        }
        do {
            try await ensureModelLoaded(modelId: modelId)
        } catch {
            // Captured BEFORE the awaits below: a retirement completing
            // during them clears its tombstone, and the reject would then
            // be misfiled as memory_cap instead of slot_state.
            let rejectedByRetirement = isRefusedByRetirement(modelId)
            profile.mark(.loadWaitEnd)
            if requestToModel.removeValue(forKey: requestId) != nil {
                powerAssertion.release()
                syncWarmModelState()
                await updateAggregateCapacity()
            }
            await cancellationRegistry.finish(requestId: requestId)
            logger.error("[\(requestId)] model load failed")
            let failure = CapacityRejectionEnrichment.enrich(
                Self.loadInferenceFailure(for: error),
                modelId: modelId,
                published: state.publishedCapacity,
                fallbackReason: rejectedByRetirement ? .slotState : .memoryCap)
            lookupReceiptFinalizer.sendTerminal(
                .inferenceError(
                    requestId: requestId,
                    failure: failure,
                    profile: profile),
                fallbackFailure: failure.code == .capacity ? .capacity : .policy,
                send: send)
            return
        }
        profile.mark(.loadWaitEnd)

        // Model loading mutates slot/Metal state and is not safely cancellable.
        // Reject immediately after the authoritative load returns.
        if await rejectAcceptedRequestIfFirstContentDeadlineExpired(
            firstContentDeadline,
            requestId: requestId,
            send: send,
            lookupReceiptFinalizer: lookupReceiptFinalizer)
        {
            return
        }

        guard requestToModel[requestId] == modelId else {
            await cancellationRegistry.finish(requestId: requestId)
            logger.info("[\(requestId)] Request cancelled during model load")
            return
        }

        guard let slot = modelSlots[modelId] else {
            if requestToModel.removeValue(forKey: requestId) != nil {
                powerAssertion.release()
                syncWarmModelState()
                await updateAggregateCapacity()
            }
            await cancellationRegistry.finish(requestId: requestId)
            logger.error("[\(requestId)] requested model disappeared after load")
            lookupReceiptFinalizer.sendTerminal(
                .inferenceError(
                    requestId: requestId,
                    failure: InferenceFailure(code: .modelUnavailable, statusCode: 503),
                    profile: profile),
                fallbackFailure: .policy,
                send: send)
            return
        }

        modelSlots[modelId]?.lastInferenceAt = .now
        syncWarmModelState()

        // 7. Capture values for the spawned task
        let responsePublicKeyData: Data = senderKey
        let kp = self.keyPair
        let providerStats = self.stats
        let registry = self.cancellationRegistry
        let signingIdentity = self.signer
        let log = self.logger
        // TTFT tracking inputs (routing v2): the tracker feeds capacity-quote
        // quantiles from completed real requests. `receivedAt` was anchored by
        // the CoordinatorClient's receive callback, so the recorded duration
        // is genuinely dispatch-received → first content token, end to end.
        // Batch occupancy comes from the latest capacity rebuild — a cheap
        // lock read that intentionally avoids an engine-actor hop; it can lag
        // one rebuild behind the engine's row count, which shifts a sample by
        // at most one batch bucket.
        let ttftTracker = state.ttftTracker
        let dispatchReceivedAt = receivedAt
        let activeRequestsAtDispatch = Int(
            state.backendCapacity?.slots.first { $0.model == modelId }?.numRunning ?? 0)
        let tokenizer = slot.tokenizer
        // Read modelType from the loaded SLOT, not advertisedModels: the latter
        // goes nil in the hard-swap drop window while the slot is still resident,
        // which would silently fall the reasoning parser back to qwen3 and leak
        // <think> tokens for a Gemma build. The slot carries the type captured at
        // load, so it is correct for startup, prefetched, AND dropped-resident.
        let modelType = slot.modelType
        let slotContainer = slot.container
        let slotIsVLM = slot.isVLM
        // ONE ENGINE (v0.7.5): the slot's v2 bridge serves every request;
        // the scheduler-free vision gate covers media decode and generation
        // memory reservations.
        let slotEngineV2 = slot.engineV2
        if prefixCacheProtocol == 2,
            let nonce = remoteCache.receiptNonce,
            let callbacks = slotEngineV2.prefixCacheEvidenceSequencer?.callbacks(
                requestID: requestId,
                nonce: nonce,
                send: send)
        {
            receiptCallbacks = (callbacks.lookup, callbacks.ready)
            lookupReceiptFinalizer.configureV2(
                lookup: callbacks.lookup,
                terminal: callbacks.terminal)
        }
        let slotVisionGate = slot.visionGate(kvBudget: kvBudget)
        // Logprobs passthrough: a per-request channel the bridge pump fills
        // with OpenAI-shaped entries and the frames loop below drains into
        // content-bearing SSE chunks. nil (request didn't ask) ⇒ frames
        // pass through untouched.
        let logprobsChannel: EngineV2LogprobsChannel? =
            logprobsSpec != nil ? EngineV2LogprobsChannel() : nil

        if await rejectAcceptedRequestIfFirstContentDeadlineExpired(
            firstContentDeadline,
            requestId: requestId,
            send: send,
            lookupReceiptFinalizer: lookupReceiptFinalizer)
        {
            return
        }

        // 8. Spawn inference task. The streaming pipeline now flows through
        // the upstream `MLXLMServer` library:
        //   - `MultiModelBatchSchedulerEngine` adapts the selected slot's
        //     EngineV2 bridge to the `MLXServerEngine` contract.
        //   - `MLXOpenAIService.streamChatCompletionFrames` formats SSE
        //     frames (matching the wire shape the coordinator already parses).
        // We encrypt each frame and forward it via `inferenceChunk` exactly
        // as before. The response hash for SE attestation is computed over
        // the assembled assistant text, extracted by parsing each emitted
        // chunk back from its JSON delta.
        let me = self
        receiptTransferredToTask = true
        profile.mark(.taskSpawned)
        let task = Task.detached {
            defer {
                lookupReceiptFinalizer.finalize(failure: .policy)
                // Profiler cancel-abort latency: only meaningful when a cancel
                // was received AND this task actually aborted (both stamps
                // set). `tokens_after_cancel_total` is NOT added here — the
                // bridge fires the builder's hook at engine finish, which may
                // be after this defer.
                if let abortNs = profile.cancelSummary().abortNs {
                    providerStats.addCancelAbortNs(UInt64(abortNs))
                }
                Task {
                    await registry.finish(requestId: requestId)
                    await me.finishInflightRequest(requestId: requestId)
                }
            }

            /// Terminal-time posture shared by EVERY terminal this task emits
            /// (complete and error): ONE lock for the frame counters, the
            /// thermal/power/MLX posture, the optional SE-sign duration, and
            /// the `terminal_built` stamp.
            let finalizeProfile: @Sendable (Int, Int, Bool, Duration?) -> Void = {
                framesEmitted, bytesEmitted, usageRecovered, seSign in
                let thermal = ProfileThermalState(ProcessInfo.processInfo.thermalState)
                let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                let mlxActive = Int64(max(0, MLX.Memory.activeMemory))
                let mlxPeak = Int64(max(0, MLX.Memory.peakMemory))
                profile.update { f, now in
                    f.set(.framesEmitted, Int64(framesEmitted))
                    f.set(.bytesEmitted, Int64(bytesEmitted))
                    f.set(.usageRecovered, usageRecovered)
                    f.thermalState = thermal
                    f.set(.lowPowerMode, lowPower)
                    f.set(.mlxActiveBytesAtFinish, mlxActive)
                    f.set(.mlxPeakBytes, mlxPeak)
                    if let seSign {
                        f.add(.seSign, us: RequestProfileBuilder.microseconds(seSign))
                    }
                    f.mark(.terminalBuilt, offsetUs: now)
                }
            }

            let rejectExpiredDeadline: @Sendable () -> Bool = {
                guard let firstContentDeadline else { return false }
                do {
                    try firstContentDeadline.check()
                    return false
                } catch let failure as PreContentDeadlineFailure {
                    finalizeProfile(0, 0, false, nil)
                    lookupReceiptFinalizer.sendTerminal(
                        .inferenceError(
                            requestId: requestId,
                            failure: CapacityRejectionEnrichment.enrich(
                                Self.inferenceFailure(for: failure),
                                modelId: modelId,
                                published: me.state.publishedCapacity,
                                fallbackReason: .deadline),
                            profile: profile),
                        fallbackFailure: .capacity,
                        send: send)
                    return true
                } catch {
                    return false
                }
            }

            if rejectExpiredDeadline() { return }

            // Phase 3: precompute the DH shared secret once per request.
            // This drops per-chunk encryption from ~150 us (full Curve25519
            // scalar multiply + XSalsa20-Poly1305) to ~1-2 us (symmetric
            // XSalsa20-Poly1305 only).  At ~1-2 us per chunk the synchronous
            // approach does not measurably affect 80 TPS decode, making an
            // async encryption queue unnecessary.
            let sharedKey: Data
            do {
                sharedKey = try kp.precomputeSharedKey(
                    recipientPublicKey: responsePublicKeyData
                )
            } catch {
                log.error("[\(requestId)] response-key setup failed")
                providerStats.incrementChunkEncryptionErrors()
                finalizeProfile(0, 0, false, nil)
                lookupReceiptFinalizer.sendTerminal(
                    .inferenceError(
                        requestId: requestId,
                        failure: InferenceFailure(
                            code: .encryptionFailure, statusCode: 502),
                        profile: profile),
                    fallbackFailure: .policy,
                    send: send)
                return
            }
            if rejectExpiredDeadline() { return }

            /// Encrypts and emits an SSE frame string. Returns `false` if
            /// encryption failed — callers must abort the inference task
            /// immediately.  Uses the precomputed DH shared key so each
            /// call is ~1-2 us (symmetric-only), not ~150 us.
            let emitSSE: @Sendable (String) -> Bool = { sseData in
                let encryptedPayload: EncryptedPayload
                do {
                    encryptedPayload = try kp.encryptPayloadFast(
                        sharedKey: sharedKey,
                        plaintext: Data(sseData.utf8)
                    )
                } catch {
                    log.error("[\(requestId)] response-chunk encryption failed")
                    providerStats.incrementChunkEncryptionErrors()
                    finalizeProfile(0, 0, false, nil)
                    lookupReceiptFinalizer.sendTerminal(
                        .inferenceError(
                            requestId: requestId,
                            failure: InferenceFailure(
                                code: .encryptionFailure, statusCode: 502),
                            profile: profile),
                        fallbackFailure: .policy,
                        send: send)
                    return false
                }

                // Direct send: bypass the OutboundRouter → AsyncStream →
                // for-await control path (whose cooperative-pool consumer is
                // starved ~30-40 ms per turn by CPU-bound MLX decode) and write
                // the chunk straight to the live NWConnection off a dedicated
                // serial queue. Ordering vs the terminal inference_complete is
                // preserved by SendHandle.send's flush barrier. Falls back to the
                // control path automatically if no direct sender is wired.
                send.sendChunk(.inferenceChunk(
                    requestId: requestId,
                    data: "",
                    encryptedData: encryptedPayload
                ))
                return true
            }

            // Per-request v2 usage-detail signal (matched + saved prefix tokens):
            // written by the bridge pump at the engine terminal, read below
            // when the trailing usage chunk arrives so cached_tokens can be
            // spliced into it. Every slot serves through v2 (v0.7.5), so
            // the signal always exists.
            // Best-effort detached delivery: callbacks never hold a cache lock
            // or delay inference terminal messages.
            let v2UsageSignal = EngineV2RequestUsageSignal(
                onLookupResolved: lookupReceiptFinalizer.resolve,
                onCacheReady: receiptCallbacks.ready)

            // Build a single-model engine view bound to the scheduler we
            // already resolved. This keeps the engine constructor's
            // "model not loaded" path unreachable on this code path while
            // still going through the upstream library for SSE encoding.
            let providerEngine = MultiModelBatchSchedulerEngine(
                registryProvider: { @Sendable in
                    [chatRequest.model: .init(
                        tokenizer: tokenizer, modelType: modelType,
                        container: slotContainer, isVLM: slotIsVLM,
                        engineV2Bridge: slotEngineV2,
                        visionGate: slotVisionGate)]
                },
                ensureLoaded: { _ in },
                reserveModel: { _ in },
                releaseModel: { _ in },
                defaultMaxTokens: Self.schedulerDefaultMaxTokens,
                templateControls: templateControls,
                cacheScope: cacheScope,
                cacheEnabled: remoteCache.cacheEnabled,
                engineV2Logprobs: logprobsChannel.map {
                    EngineV2LogprobsPlumbing(
                        topLogprobs: logprobsSpec?.topLogprobs, channel: $0)
                },
                engineV2Sampling: samplingOverrides,
                engineV2Usage: v2UsageSignal,
                firstContentDeadline: firstContentDeadline,
                profile: profile
            )

            // Force-stream so we get SSE frames even if the original request
            // had `stream: false`. The coordinator always uses streaming
            // chunks on the wire today; non-streaming consumers reassemble
            // on their end.
            //
            // Also force `streamOptions.includeUsage = true`. Without it,
            // upstream's `MLXOpenAIService.streamChatCompletionFrames` will
            // not emit the trailing usage chunk (see
            // `libs/mlx-swift-lm/Libraries/MLXLMServer/Runtime/MLXOpenAIService.swift`
            // line 88: `let includeUsage = request.streamOptions?.includeUsage == true`).
            // Missing usage means `parseStreamChunk` never extracts
            // `promptTokens`/`completionTokens`, and the coordinator bills
            // $0 for the request. This is the C1 fix.
            var streamingRequest = chatRequest
            streamingRequest.stream = true
            var forcedStreamOptions = streamingRequest.streamOptions
                ?? OpenAIStreamOptions()
            forcedStreamOptions.includeUsage = true
            streamingRequest.streamOptions = forcedStreamOptions

            // Auto-select reasoning parser based on model type if the
            // consumer didn't specify one. This ensures model-specific
            // reasoning tokens (Harmony channels, Gemma4 channels,
            // Qwen3/DeepSeek <think> tags) are parsed into
            // reasoning_content rather than leaking as raw content.
            if streamingRequest.reasoningParser == nil {
                streamingRequest.reasoningParser = Self.inferReasoningParser(for: modelType)
            }

            let service = MLXOpenAIService(engine: providerEngine)
            let frames: AsyncThrowingStream<String, Error>
            do {
                if rejectExpiredDeadline() { return }
                frames = try await service.streamChatCompletionFrames(
                    request: streamingRequest
                )
                if rejectExpiredDeadline() { return }
            } catch {
                // A cancel that lands while the stream is STARTING — the
                // consumer cancelled during prompt templating or the v0.7.5
                // vision-feature construction (`handleCancellation` cancels
                // this detached task, and the vision seam rethrows
                // CancellationError instead of falling back to legacy) — is
                // not a provider fault. Report it exactly like the
                // established "cancelled with nothing delivered" terminal
                // below (499 + "request cancelled", cancellations-before-
                // output stat), never a mapped 500 .inferenceError, which
                // would count as a provider error and trip the
                // (provider, model) 5xx routing cooldown for a client's own
                // cancel.
                if error is CancellationError || token.isCancelled {
                    log.info("[\(requestId)] Request cancelled while starting the stream")
                    providerStats.incrementCancellationsBeforeOutput()
                    profile.mark(.cancelAborted)
                    finalizeProfile(0, 0, false, nil)
                    lookupReceiptFinalizer.sendTerminal(
                        .inferenceError(
                            requestId: requestId,
                            failure: InferenceFailure(
                                code: .cancelled,
                                statusCode: 499,
                                // Pre-output client cancellation — tag it so the
                                // coordinator classifies this health-neutral (never
                                // a provider fault). Nothing was delivered, so no
                                // attempt usage rides along (the coordinator refunds).
                                terminalCause: .cancelled),
                            profile: profile),
                        fallbackFailure: .policy,
                        send: send)
                    return
                }
                if let failure = error as? PreContentDeadlineFailure {
                    log.info("[\(requestId)] Refusing pre-content request: \(failure.rawValue)")
                    finalizeProfile(0, 0, false, nil)
                    lookupReceiptFinalizer.sendTerminal(
                        .inferenceError(
                            requestId: requestId,
                            failure: CapacityRejectionEnrichment.enrich(
                                Self.inferenceFailure(for: failure),
                                modelId: modelId,
                                published: me.state.publishedCapacity,
                                fallbackReason: .deadline),
                            profile: profile),
                        fallbackFailure: .capacity,
                        send: send)
                    return
                }
                let reason = classifyInferenceErrorReason(error)
                let failure = Self.sanitizedInferenceFailure(
                    from: error,
                    phase: .streamStart,
                    errorReason: reason)
                InferenceFailureLogger(logger: log).record(
                    requestId: requestId,
                    failure: failure)
                // Classify HERE, where the real `Error` (and its rich
                // `String(describing:)` text) is in scope. For a Harmony
                // TemplateException `error.localizedDescription` collapses to the
                // lossy "(Jinja.TemplateException error 1.)", so the only place we
                // can tell channel-tags from null-bridge from a generic template
                // failure is at this catch (DAR-341). We send ONLY the normalized
                // reason on the wire — never the rich text, which can carry prompt
                // content (E2E privacy).
                if let reason,
                    reason == .jinjaChannelTags || reason == .jinjaNullBridge
                {
                    // Privacy-safe diagnostic: log the OFFENDING message's index +
                    // role only — never its content. `templateMessageDict()` yields
                    // the same dict shape handed to the chat template.
                    if let location = offendingHarmonyMessageLocation(
                        in: streamingRequest.messages.map { $0.templateMessageDict() }
                    ) {
                        log.error(
                            "[\(requestId)] Harmony template render failed reason=\(reason.rawValue); "
                            + "offending message index=\(location.index) role=\(location.role) "
                            + "(content omitted for privacy)"
                        )
                    } else {
                        log.error(
                            "[\(requestId)] Harmony template render failed reason=\(reason.rawValue); "
                            + "offending message not located (content omitted for privacy)"
                        )
                    }
                }
                finalizeProfile(0, 0, false, nil)
                lookupReceiptFinalizer.sendTerminal(
                    .inferenceError(
                        requestId: requestId,
                        // Enrich the capacity-shaped engine rejections (queue
                        // full, token budget, KV headroom — the live gate's
                        // fast rejects) with the published snapshot; non-
                        // capacity failures pass through unchanged. The token
                        // envelope (evaluated lazily, token_budget shape only)
                        // lets the enrichment stamp a real feasible_after_ms
                        // busy-wait forecast.
                        failure: CapacityRejectionEnrichment.enrich(
                            failure,
                            modelId: modelId,
                            published: me.state.publishedCapacity,
                            fallbackReason: .tokenBudget,
                            neededTokens: Self.admissionTokenEnvelope(
                                request: streamingRequest,
                                tokenizer: tokenizer,
                                modelType: modelType,
                                templateControls: templateControls)),
                        profile: profile),
                    fallbackFailure: failure.statusCode == 503 ? .capacity : .policy,
                    send: send)
                return
            }

            await me.updateAggregateCapacity()
            if rejectExpiredDeadline() { return }

            var fullResponseText = ""
            var promptTokens = 0
            var completionTokens = 0
            // Profiler frame counters (locals; written to the profile once at
            // the terminal — never a per-frame lock).
            var framesEmitted = 0
            var bytesEmitted = 0
            var usageRecovered = false
            // Defense-in-depth for the billing-zero leak: count SSE frames that
            // carried visible output. If the usage chunk is lost entirely
            // (parser drift / upstream regression), this is a conservative
            // lower-bound floor for completion tokens so a request that clearly
            // produced output never settles at 0 (which the coordinator would
            // fully refund). MLX streams ~1 token per frame, so this slightly
            // under-counts vs. true tokenization but never bills $0 for work.
            var contentFrameCount = 0
            // End-to-end TTFT (dispatch-received → first content token),
            // captured at the first content-bearing frame and committed to
            // the tracker only on clean completion (routing v2 quotes must
            // calibrate on completed real requests). Duration only.
            var firstContentElapsedMs: Double?
            // Accumulated `reasoning_content` deltas (gpt-oss analysis
            // channel, Qwen3/DeepSeek <think>, Gemma4 channels). Re-tokenized
            // at completion to report an accurate `reasoning_tokens` count —
            // upstream's usage block only carries the total completion count.
            var reasoningText = ""
            var reasoningTokens = 0

            // A cancelled request that already streamed output settles through
            // the completion path below with real usage, not a bare 499 ($0).
            var cancelledMidStream = false
            // Logprobs entries drained from the v2 bridge but not yet
            // attached to a frame. Entries attach to the NEXT content-
            // bearing chunk (role preambles / reasoning-only deltas /
            // usage chunks are skipped); consumers accumulate
            // `logprobs.content` across chunks, so chunk-boundary
            // alignment is not load-bearing — order and exactly-once are.
            //
            // BOUNDED (round-3 PR#499 P2): a long reasoning-only/tool-only
            // prefix (GPT-OSS) drains the capped channel here every frame
            // without ever clearing, so this buffer is re-capped after each
            // drain with the SAME drop-oldest policy as the channel
            // (`EngineV2LogprobsChannel.capPending`); the freshest window —
            // the entries nearest the content that eventually renders — is
            // kept and the dropped count is logged (never token text).
            var pendingLogprobs: [SSETokenLogprob] = []
            var pendingLogprobsDropped = 0
            // One decoder per request, not one per frame.
            let chunkDecoder = JSONDecoder()
            // Frames the decoder rejected: forwarded verbatim but invisible
            // to the hash / billing floor / TTFT sample. First one warns,
            // the total is logged at stream end (same pattern as logprobs).
            var unparsedFrames = 0
            do {
                for try await frame in frames {
                    // The iterator suspension is the final pre-content await.
                    // Role/usage boilerplate is not content, so keep enforcing
                    // the same absolute deadline until a real content,
                    // reasoning, or tool delta has been observed.
                    if contentFrameCount == 0, rejectExpiredDeadline() {
                        return
                    }
                    if token.isCancelled {
                        log.info("[\(requestId)] Cancelled during generation")
                        cancelledMidStream = true
                        profile.mark(.cancelAborted)
                        break  // exiting propagates the abort via onTermination
                    }
                    // Aggregate the assistant text + usage by parsing each
                    // chunk back from its JSON delta. This is the cost of
                    // routing through `streamChatCompletionFrames` instead
                    // of the raw engine event stream — but the alternative
                    // is duplicating SSE encoding logic.
                    //
                    // TB-007: hash domain = content + reasoning_content + tool_calls (canonicalized).
                    // - `content` and `reasoning_content` are concatenated
                    //   verbatim so the hash matches the engine's emitted
                    //   bytes (and what the consumer reassembles after SSE
                    //   parsing). When `reasoning_parser` is set, upstream
                    //   splits `<think>...</think>` blocks into the
                    //   `reasoning_content` delta field, so hashing only
                    //   the visible `content` would commit to a different
                    //   set of bytes than what the engine produced.
                    // - `tool_calls` are folded in via
                    //   `encodeToolCallsForHash(_:)` (P2 #2). Tool-calling
                    //   responses often carry empty `content` with the
                    //   real assistant output on `delta.tool_calls`; a
                    //   hash that ignored them would commit to (near-)
                    //   empty bytes instead of the actual output.
                    var frameToEmit = frame
                    let parsed = Self.parseStreamChunk(frame, decoder: chunkDecoder)
                    if Self.isUnparsedStreamFrame(frame, parsed: parsed) {
                        unparsedFrames += 1
                        if unparsedFrames == 1 {
                            log.warning(
                                "[\(requestId)] SSE frame did not parse (\(frame.utf8.count) bytes); "
                                + "forwarded verbatim but excluded from hash/billing/TTFT bookkeeping"
                            )
                        }
                    }
                    if let parsed {
                        var frameHadContent = false
                        if let content = parsed.contentDelta {
                            fullResponseText += content
                            // Count only NON-empty content toward the billing
                            // floor: parseStreamChunk returns a non-nil but empty
                            // contentDelta for SSE frames carrying "content":""
                            // (role/terminal deltas), which produce no visible
                            // output and must not be billed.
                            if !content.isEmpty {
                                frameHadContent = true
                            }
                        }
                        if let reasoning = parsed.reasoningDelta, !reasoning.isEmpty {
                            fullResponseText += reasoning
                            frameHadContent = true
                            reasoningText += reasoning
                        }
                        if let toolCalls = parsed.toolCallsDelta, !toolCalls.isEmpty {
                            fullResponseText += Self.encodeToolCallsForHash(toolCalls)
                            frameHadContent = true
                        }
                        if frameHadContent {
                            // First content frame (both counters flip here,
                            // so one check suffices).
                            if contentFrameCount == 0 {
                                let elapsed = ContinuousClock.Instant.now - dispatchReceivedAt
                                firstContentElapsedMs =
                                    Double(elapsed.components.seconds) * 1000.0
                                    + Double(elapsed.components.attoseconds) / 1e15
                            }
                            contentFrameCount += 1
                            if contentFrameCount == 1 {
                                // First content-bearing frame seen by the
                                // provider loop (once per request).
                                profile.mark(.firstFrame)
                            }
                        }
                        if let usage = parsed.usage {
                            promptTokens = usage.promptTokens
                            completionTokens = usage.completionTokens
                            // The usage block rides the final chunk, after all
                            // reasoning deltas, so `reasoningText` is complete
                            // here. Re-tokenize it for an accurate count and
                            // surface it to chat-completions consumers via
                            // `usage.completion_tokens_details.reasoning_tokens`
                            // (OpenAI shape). The coordinator forwards this
                            // chunk verbatim, so no coordinator change is
                            // needed for the streaming path.
                            if !reasoningText.isEmpty {
                                // Re-tokenizing detokenized text isn't a perfect
                                // identity (whitespace/special-token merges), so
                                // clamp to the engine's completion count — a
                                // reasoning subset can never exceed the total.
                                reasoningTokens = min(
                                    tokenizer.inner.encode(
                                        text: reasoningText, addSpecialTokens: false
                                    ).count,
                                    max(0, completionTokens)
                                )
                            }
                            // v2 prefix cache (T-041): OpenAI-standard
                            // `prompt_tokens_details.cached_tokens` on the
                            // trailing usage chunk. The bridge pump recorded
                            // the signal BEFORE yielding its terminal, which
                            // happens-before this usage frame was encoded, so
                            // the read is never racy. Billing is unaffected —
                            // the coordinator settles from inference_complete,
                            // not from this field.
                            // Both details are spliced in ONE JSON round trip;
                            // absent/zero values leave the frame untouched.
                            frameToEmit = Self.injectUsageDetails(
                                into: frame,
                                reasoningTokens: reasoningTokens,
                                cachedTokens: v2UsageSignal.prefixCacheHitTokens ?? 0
                            )
                        }
                    }
                    // Logprobs passthrough (v2 only): splice pending entries
                    // into this frame if it carries content; otherwise keep
                    // them pending. Runs AFTER the hash/usage bookkeeping
                    // above, which reads the original `frame` — logprobs
                    // never alter `delta.content`, so the response hash and
                    // billing extraction are unaffected.
                    if let logprobsChannel {
                        pendingLogprobs += logprobsChannel.drain()
                        // Re-cap after every drain: without a content-bearing
                        // frame this buffer would grow unbounded past the
                        // channel's own cap (see the declaration comment).
                        let dropped = EngineV2LogprobsChannel.capPending(&pendingLogprobs)
                        if dropped > 0 {
                            if pendingLogprobsDropped == 0 {
                                log.warning(
                                    "[\(requestId)] pending logprobs hit the "
                                    + "\(EngineV2LogprobsChannel.maxEntries)-entry cap before a "
                                    + "content-bearing frame; dropping oldest entries (count only)"
                                )
                            }
                            pendingLogprobsDropped += dropped
                        }
                        if !pendingLogprobs.isEmpty,
                            let injected = Self.injectLogprobs(
                                into: frameToEmit, entries: pendingLogprobs)
                        {
                            frameToEmit = injected
                            pendingLogprobs = []
                        }
                    }
                    if !emitSSE(frameToEmit) { return }
                    framesEmitted += 1
                    bytesEmitted += frameToEmit.utf8.count
                }
            } catch {
                // Cancellation can throw here or end the stream as a clean
                // nil-end (caught after the loop); both settle as a cancel.
                if error is CancellationError || token.isCancelled {
                    log.info("[\(requestId)] Cancelled while waiting on next frame")
                    cancelledMidStream = true
                    profile.mark(.cancelAborted)
                } else {
                    let failure = Self.sanitizedInferenceFailure(
                        from: error,
                        phase: .generation)
                    InferenceFailureLogger(logger: log).record(
                        requestId: requestId,
                        failure: failure)
                    if Self.hasVisibleStreamOutput(
                        contentFrameCount: contentFrameCount,
                        fullResponseText: fullResponseText
                    ) {
                        providerStats.incrementGenerationErrorsAfterOutput()
                    }
                    if Self.isStreamClosedWithoutTerminal(error) {
                        providerStats.incrementStreamClosedWithoutTerminal()
                    }
                    // Mid-stream generation errors use typed classification only:
                    // tool-choice violations are request/model-output faults, while
                    // string-based Jinja classification remains confined to stream
                    // startup. Finalize the lookup receipt first so the cache attempt
                    // cannot survive this terminal path.
                    finalizeProfile(framesEmitted, bytesEmitted, false, nil)
                    lookupReceiptFinalizer.sendTerminal(
                        .inferenceError(
                            requestId: requestId,
                            failure: failure,
                            profile: profile),
                        fallbackFailure: failure.statusCode == 503 ? .capacity : .policy,
                        send: send)
                    return
                }
            }
            if token.isCancelled {
                cancelledMidStream = true
                profile.mark(.cancelAborted)
            }

            if pendingLogprobsDropped > 0 {
                // Surface the request's TOTAL evicted-entry count once at
                // stream end (the in-loop WARN fires only on the first drop).
                log.warning(
                    "[\(requestId)] dropped \(pendingLogprobsDropped) pending logprob "
                    + "entries in total (buffer cap \(EngineV2LogprobsChannel.maxEntries))"
                )
            }
            if unparsedFrames > 1 {
                log.warning(
                    "[\(requestId)] \(unparsedFrames) SSE frames did not parse in total"
                )
            }

            if cancelledMidStream {
                // In the normal cancel ordering the frames loop breaks before
                // any usage frame, so `promptTokens` is still 0 here. The
                // bridge published the engine's exact prompt count when the
                // pump started; billing it (the same number a clean finish
                // bills) makes `promptTokenFloor` — a full chat-template
                // re-render plus BPE — unnecessary: the autoclosure below is
                // only evaluated while promptTokens == 0.
                if promptTokens == 0, let enginePrompt = v2UsageSignal.promptTokens,
                    enginePrompt > 0
                {
                    promptTokens = enginePrompt
                }
                if reasoningTokens == 0 && !reasoningText.isEmpty {
                    let completionFloor = completionTokens > 0 ? completionTokens : contentFrameCount
                    if completionFloor > 0 {
                        reasoningTokens = min(
                            tokenizer.inner.encode(
                                text: reasoningText, addSpecialTokens: false
                            ).count,
                            completionFloor
                        )
                    }
                }

                let deliveredCompletionTokenFloor = tokenizer.inner.encode(
                    text: fullResponseText, addSpecialTokens: false
                ).count
                if completionTokens == 0, let engineCompletion = v2UsageSignal.completionTokens {
                    // Measurement hook, NOT billed: the engine forwarded
                    // `engineCompletion` tokens by the time the pump last
                    // wrote, while the delivered-text re-encode floors at
                    // `deliveredCompletionTokenFloor`. The gap is the parser
                    // holdback plus whatever sat in the downstream streams at
                    // cancel; billing the engine count is gated on this
                    // distribution measured over real cancels.
                    log.info(
                        "[\(requestId)] cancel settlement: engine_completion=\(engineCompletion) "
                        + "delivered_floor=\(deliveredCompletionTokenFloor) "
                        + "delta=\(engineCompletion - deliveredCompletionTokenFloor)"
                    )
                }
                let partialUsage = StreamedGenerationUsage(
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    reasoningTokens: reasoningTokens,
                    contentFrameCount: contentFrameCount,
                    deliveredCompletionTokenFloor: deliveredCompletionTokenFloor,
                    hasVisibleOutput: Self.hasVisibleStreamOutput(
                        contentFrameCount: contentFrameCount,
                        fullResponseText: fullResponseText
                    )
                )
                let terminal = partialUsage.cancelledTerminal(promptTokenFloor: Self.promptTokenFloor(
                    request: streamingRequest,
                    tokenizer: tokenizer,
                    modelType: modelType,
                    templateControls: templateControls
                ))
                guard case .complete(let settledUsage) = terminal else {
                    // Cancelled with nothing delivered: 499 so the coordinator refunds.
                    providerStats.incrementCancellationsBeforeOutput()
                    finalizeProfile(framesEmitted, bytesEmitted, false, nil)
                    lookupReceiptFinalizer.sendTerminal(
                        .inferenceError(
                            requestId: requestId,
                            failure: InferenceFailure(
                                code: .cancelled,
                                statusCode: 499,
                                // Pre-output client cancellation — tag it so the
                                // coordinator classifies this health-neutral (never
                                // a provider fault). Nothing was delivered, so no
                                // attempt usage rides along (the coordinator refunds).
                                terminalCause: .cancelled),
                            profile: profile),
                        fallbackFailure: .policy,
                        send: send)
                    return
                }
                if completionTokens == 0 {
                    log.warning(
                        "[\(requestId)] usage chunk missing/zero completion tokens (cancelled mid-stream); "
                        + "billing \(settledUsage.completionTokens) delivered completion tokens as a floor."
                    )
                }
                if promptTokens == 0 && settledUsage.promptTokens > 0 {
                    log.warning(
                        "[\(requestId)] usage chunk missing/zero prompt tokens (cancelled mid-stream); "
                        + "billing \(settledUsage.promptTokens) re-templated prompt tokens as a floor."
                    )
                }
                promptTokens = Int(clamping: settledUsage.promptTokens)
                completionTokens = Int(clamping: settledUsage.completionTokens)
                reasoningTokens = Int(clamping: settledUsage.reasoningTokens)
            }

            // No usage chunk on a clean finish means an upstream regression.
            // Recover a billing floor: completion = content-frame count (~1
            // token/frame); prompt = re-template via the engine's exact
            // applyChatTemplate path. VLM prompts under-count (no image tokens) —
            // a floor, never an overcharge.
            if !cancelledMidStream && (promptTokens == 0 || completionTokens == 0) {
                if completionTokens == 0 && contentFrameCount > 0 {
                    completionTokens = contentFrameCount
                    log.warning(
                        "[\(requestId)] usage chunk missing/zero completion tokens"
                        + "; "
                        + "billing \(contentFrameCount) observed content frames as a floor."
                    )
                }
                if promptTokens == 0 {
                    promptTokens = Self.promptTokenFloor(
                        request: streamingRequest,
                        tokenizer: tokenizer,
                        modelType: modelType,
                        templateControls: templateControls
                    )
                    if promptTokens > 0 {
                        log.warning(
                            "[\(requestId)] usage chunk missing/zero prompt tokens"
                            + "; "
                            + "billing \(promptTokens) re-templated prompt tokens as a floor."
                        )
                    }
                }
                // Re-tokenize reasoning here too when the usage frame is missing.
                if reasoningTokens == 0 && !reasoningText.isEmpty && completionTokens > 0 {
                    reasoningTokens = min(
                        tokenizer.inner.encode(
                            text: reasoningText, addSpecialTokens: false
                        ).count,
                        completionTokens
                    )
                }
                if promptTokens == 0 || completionTokens == 0 {
                    log.warning(
                        "[\(requestId)] CRITICAL: usage missing after recovery "
                        + "(promptTokens=\(promptTokens), "
                        + "completionTokens=\(completionTokens), "
                        + "contentFrames=\(contentFrameCount)). "
                        + "Billing will be undercounted. Check upstream "
                        + "MLXOpenAIService.streamChatCompletionFrames behavior."
                    )
                }
                // Surface to `doctor` — but not for a cancel, where a missing
                // final chunk is expected, not an upstream anomaly.
                if !cancelledMidStream {
                    providerStats.incrementUsageGaps()
                }
                usageRecovered = true
            }

            if cancelledMidStream {
                providerStats.incrementCancellationsPartialComplete()
            }

            // Update stats
            providerStats.incrementRequestsServed()
            providerStats.addTokensGenerated(UInt64(max(completionTokens, 0)))

            // Commit the TTFT sample (routing v2): completed real requests
            // only — a cancelled stream's first-token timing is still real,
            // but the plan calibrates quotes on clean completions so partial
            // settles cannot skew the distribution during incident churn.
            if !cancelledMidStream, let ttftMs = firstContentElapsedMs {
                ttftTracker.record(
                    model: modelId,
                    warm: modelWasResidentAtDispatch,
                    promptTokens: promptTokens,
                    activeRequestsAtDispatch: activeRequestsAtDispatch,
                    ttftMs: ttftMs)
            }

            // Update state
            await me.updateAggregateCapacity()

            // Send completion
            let seSignStart = SuspendingClock.now
            let attestation = computeResponseAttestation(
                identity: signingIdentity,
                requestId: requestId,
                completionTokens: UInt64(max(completionTokens, 0)),
                responseBody: fullResponseText
            )
            let seSignDuration = SuspendingClock.now - seSignStart
            let cacheResult = remoteCache.scope == nil ? nil : v2UsageSignal.lookupResult
            let usageInfo = UsageInfo(
                promptTokens: UInt64(max(0, promptTokens)),
                completionTokens: UInt64(max(0, completionTokens)),
                reasoningTokens: UInt64(max(0, reasoningTokens)),
                cacheOutcome: cacheResult?.outcome,
                cacheTier: cacheResult?.tier,
                cachedTokens: cacheResult.map { UInt64(max(0, $0.cachedTokens)) },
                prefillTokensSaved: cacheResult.map { UInt64(max(0, $0.prefillTokensSaved)) },
                cacheStageMs: cacheResult?.stageMs
            )
            finalizeProfile(framesEmitted, bytesEmitted, usageRecovered, seSignDuration)
            lookupReceiptFinalizer.sendTerminal(
                .inferenceComplete(
                    requestId: requestId,
                    usage: usageInfo,
                    stopSequence: v2UsageSignal.matchedStopSequence,
                    seSignature: attestation.signature,
                    responseHash: attestation.hash,
                    // Live builder: SendHandle.send stamps flush/terminal_sent,
                    // the codec materializes the wire object at encode time.
                    profile: profile),
                fallbackFailure: .policy,
                send: send)

            log.info(
                "[\(requestId)] Complete\(cancelledMidStream ? " (cancelled mid-stream, partial settle)" : ""): "
                + "\(promptTokens) prompt + \(completionTokens) completion tokens")
        }

        inflightTasks[requestId] = task
        if completedBeforeTaskRegistration.remove(requestId) != nil {
            inflightTasks.removeValue(forKey: requestId)
        }
        modelSlots[modelId]?.lastInferenceAt = .now
    }

}
