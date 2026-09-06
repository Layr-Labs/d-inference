// Tokenization, cache staging, and engine submission.

import Foundation
import MLXLMCommon
import ProviderCoreFoundation

extension EngineV2Bridge {
    // MARK: - Submit

    /// Tokenize local role/content messages, stripping Harmony framing from
    /// assistant history. Authenticated remote requests use submitTokenized.
    public func submit(
        request: ChatCompletionRequest,
        requestId: String? = nil,
        logprobsChannel: EngineV2LogprobsChannel? = nil
    ) async -> AsyncStream<GenerationEvent> {
        let messages: [[String: any Sendable]] = request.messages.map { msg in
            [
                "role": msg.role,
                "content": msg.role == "assistant"
                    ? stripHarmonyChannelFraming(fromAssistantContent: msg.content)
                    : msg.content,
            ]
        }
        let promptTokens: [Int]
        do {
            promptTokens = try tokenizer.inner.applyChatTemplate(
                messages: messages, tools: nil, additionalContext: nil
            )
        } catch {
            let (stream, continuation) = AsyncStream<GenerationEvent>.makeStream()
            continuation.yield(.error("Failed to tokenize: \(error.localizedDescription)"))
            continuation.finish()
            return stream
        }
        return await submitTokenized(
            promptTokens: promptTokens, request: request, requestId: requestId,
            cacheScope: "", logprobsChannel: logprobsChannel
        )
    }

    /// Submit a prompt already tokenized by MultiModelBatchSchedulerEngine,
    /// using the same sampling, stop, and token-limit translation as submit.
    /// Remote cacheScope values come from authenticated coordinator metadata;
    /// local callers remain unscoped and cacheEnabled=false forces cold serving.
    /// usageSignal and logprobsChannel carry per-request output metadata.
    /// Multimodal embeddings must already be evaluated; mediaKind is telemetry.
    public func submitTokenized(
        promptTokens: [Int],
        request: ChatCompletionRequest,
        requestId: String? = nil,
        cacheScope: String = "",
        cacheEnabled: Bool = true,
        logprobsChannel: EngineV2LogprobsChannel? = nil,
        usageSignal: EngineV2RequestUsageSignal? = nil,
        multimodal: CBv2MultimodalInput? = nil,
        positionState: CBv2PositionState? = nil,
        mediaKind: EngineV2MediaKind? = nil,
        tokenConstraint: (any CBv2TokenConstraint)? = nil
    ) async -> AsyncStream<GenerationEvent> {
        do {
            return try await submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: requestId,
                cacheScope: cacheScope,
                cacheEnabled: cacheEnabled,
                logprobsChannel: logprobsChannel,
                usageSignal: usageSignal,
                multimodal: multimodal,
                positionState: positionState,
                mediaKind: mediaKind,
                tokenConstraint: tokenConstraint,
                firstContentDeadline: nil)
        } catch {
            // A nil deadline cannot produce the only thrown error in the
            // deadline-aware overload. Keep local callers non-throwing
            // without turning a future invariant violation into a process crash.
            let (stream, continuation) = AsyncStream<GenerationEvent>.makeStream()
            usageSignal?.finalizeLookup(
                failure: .policy,
                fallbackTier: prefixCacheFallbackTier)
            continuation.yield(.error("request rejected before engine submission"))
            continuation.finish()
            return stream
        }
    }

    /// Deadline-aware remote submission. The absolute deadline was derived
    /// once at coordinator-frame receipt and converted to a remaining
    /// monotonic duration only at atomic engine admission. Existing local/test
    /// callers use the non-throwing overload.
    public func submitTokenized(
        promptTokens: [Int],
        request: ChatCompletionRequest,
        requestId: String? = nil,
        cacheScope: String = "",
        cacheEnabled: Bool = true,
        logprobsChannel: EngineV2LogprobsChannel? = nil,
        usageSignal: EngineV2RequestUsageSignal? = nil,
        multimodal: CBv2MultimodalInput? = nil,
        positionState: CBv2PositionState? = nil,
        mediaKind: EngineV2MediaKind? = nil,
        tokenConstraint: (any CBv2TokenConstraint)? = nil,
        firstContentDeadline: FirstContentDeadline?,
        profile: RequestProfileBuilder? = nil
    ) async throws -> AsyncStream<GenerationEvent> {
        // Validate the caller-supplied id before it becomes a dictionary key /
        // cancel-correlation handle: a nil / empty / over-long / non-printable
        // id is replaced with a fresh generated one (it could never correlate
        // a cancel reliably anyway, and an unbounded/control-char key is a
        // hardening risk). See `normalizedRequestId`.
        let id = Self.normalizedRequestId(requestId)
        let (stream, continuation) = AsyncStream<GenerationEvent>.makeStream()

        // Duplicate request-id guard (legacy: the planner's
        // `duplicateRequestID` rejection). Without it a second submit under
        // the same id would overwrite the first request's bookkeeping and
        // the two pumps would corrupt each other's teardown. Same canonical
        // message → `.requestRejected` (a deterministic client fault).
        guard active[id] == nil, !pendingSubmissionIDs.contains(id) else {
            usageSignal?.finalizeLookup(
                failure: .policy,
                fallbackTier: prefixCacheFallbackTier)
            continuation.yield(.error("token_budget_exhausted: duplicate request ID"))
            continuation.finish()
            return stream
        }
        let retirementTransfer = EngineV2RetirementTransfer()
        pendingSubmissionIDs.insert(id)
        if let profile { pendingProfiles[id] = profile }
        // Profiler: this prompt is "queued for prefill" for exactly the span
        // of this call (every exit path, admitted or rejected).
        queuedPrefillTokens += promptTokens.count
        defer { queuedPrefillTokens = max(0, queuedPrefillTokens - promptTokens.count) }
        defer {
            if !retirementTransfer.isClaimed {
                pendingSubmissionIDs.remove(id)
                pendingCancellationIDs.remove(id)
                pendingProfiles.removeValue(forKey: id)
            }
        }
        #if DEBUG
        if let gate = _testPreSubmitGate {
            _testPreSubmitGate = nil
            await gate()
        }
        #endif
        try await checkFirstContentDeadline(
            firstContentDeadline,
            requestID: id,
            sharedKVReserved: false,
            prefixCacheReceiptID: nil,
            ssdStaged: false,
            readyReceiptRegistered: false,
            usageSignal: usageSignal)

        // Translate with a PLACEHOLDER engine id — the real id is minted
        // below, AFTER the shared-budget await, in the same synchronous
        // stretch as `engine.submit` and the `idMap` registration. Validate
        // total token arithmetic before minting cache tickets or staging.
        var cbv2Request = EngineV2Translation.cbv2Request(
            id: CBv2RequestID(0),
            promptTokens: promptTokens,
            request: request,
            defaultMaxTokens: defaultMaxTokens,
            stopTokenIds: stopTokenIds,
            cacheScope: cacheScope,
            cacheEnabled: cacheEnabled,
            multimodal: multimodal,
            tokenConstraint: tokenConstraint
        )
        cbv2Request.positionState = positionState ?? multimodal?.positionState
        try await checkFirstContentDeadline(
            firstContentDeadline,
            requestID: id,
            sharedKVReserved: false,
            prefixCacheReceiptID: nil,
            ssdStaged: false,
            readyReceiptRegistered: false,
            usageSignal: usageSignal)
        let (worstCaseTokens, tokenCountOverflow) = promptTokens.count.addingReportingOverflow(
            cbv2Request.maxTokens)
        guard !tokenCountOverflow else {
            usageSignal?.finalizeLookup(
                failure: .capacity,
                fallbackTier: prefixCacheFallbackTier)
            continuation.yield(.error(
                "token_budget_exhausted: request token count overflow"))
            continuation.finish()
            return stream
        }

        // Prefer resident pages when they save at least as much prefill as
        // the durable tier. A shorter memory hit must not hide a longer SSD
        // prefix. Both probes are advisory; staging authenticates disk bytes
        // and the engine revalidates page generations before adoption.
        let residentPrefixCandidate: CBv2ResidentPrefixCandidate? =
            cacheEnabled && multimodal == nil
            ? ownedEngine?.residentPrefixCandidate(for: cbv2Request) : nil
        if residentPrefixCandidate != nil {
            usageSignal?.recordResidentPrefixCandidate()
        }

        // Sampling IDs may repeat for seeded requests; publication tickets
        // identify this concrete submission across both resident and SSD tiers.
        let prefixCacheReceiptID: CBv2RequestID?
        var readyReceiptRegistered = false
        if cacheEnabled, multimodal == nil,
            ssdPrefixCache != nil || ssdHybridCheckpointStore != nil || residentPrefixCacheEvidence != nil
        {
            let receiptID = mintPrefixCacheReceiptID()
            prefixCacheReceiptID = receiptID
            if let ssd = ssdPrefixCache, let callback = usageSignal?.onCacheReady {
                ssd.registerReadyReceipt(requestID: receiptID, callback: callback)
                readyReceiptRegistered = true
            }
            if let store = ssdHybridCheckpointStore, let callback = usageSignal?.onCacheReady {
                store.registerReadyReceipt(requestID: receiptID, promptTokens: promptTokens,
                                           cacheScope: cacheScope, callback: callback)
                readyReceiptRegistered = true
            }
            if let evidence = residentPrefixCacheEvidence, let usageSignal,
                let proof = evidence.promptProof(tokens: promptTokens, scope: cacheScope)
            {
                usageSignal.recordResidentPrompt(proof)
                evidence.register(receiptID: receiptID, signal: usageSignal)
            }
        } else {
            prefixCacheReceiptID = nil
        }

        var pumpOwnsPrefixResources = false
        defer {
            if !pumpOwnsPrefixResources, !retirementTransfer.isClaimed, let prefixCacheReceiptID {
                residentPrefixCacheEvidence?.discard(receiptID: prefixCacheReceiptID)
                ssdHybridCheckpointStore?.completeStaging(requestID: prefixCacheReceiptID)
                ssdHybridCheckpointStore?.discardReadyReceipt(requestID: prefixCacheReceiptID)
            }
        }

        // After a resident miss or a longer durable match, rehydrate eligible
        // SSD blocks off the engine queue so synchronous lookup can adopt them.
        // The engine balances successful staging via
        // endAdoption; rejection and terminal paths provide an idempotent
        // backstop. Vision requests never stage.
        var ssdStaged = false
        var ssdReuseAttempted = false
        cbv2Request.prefixCacheReceiptID = prefixCacheReceiptID
        if !cacheEnabled {
            usageSignal?.recordCacheDisabled(tier: prefixCacheFallbackTier)
        } else if multimodal != nil {
            usageSignal?.finalizeLookup(
                failure: .policy,
                fallbackTier: prefixCacheFallbackTier)
        } else if let store = ssdHybridCheckpointStore, let prefixCacheReceiptID,
            let liveEngine = ownedEngine as? EngineV2
        {
            let stageStart = SuspendingClock.now
            let importRequest = cbv2Request
            let stageResult = await store.stage(requestID: prefixCacheReceiptID, request: importRequest,
                reserveReadScratch: { try liveEngine.reserveCompleteCheckpointReadScratch() }) {
                try liveEngine.planCompleteCheckpointImport(manifest: $0, request: importRequest)
            }
            profile?.markDuration(.ssdStage, start: stageStart)
            ssdStaged = stageResult.staged
            ssdReuseAttempted = stageResult.staged
            usageSignal?.record(stageResult: stageResult)
            if case .skippedCapacity = stageResult.disposition {
                emitPrefixCacheColdFallback(requestId: id, reason: "stage_capacity", capacityRefusal: true)
            }
        } else if let ssd = ssdPrefixCache, let prefixCacheReceiptID,
            residentPrefixCandidate == nil
                || ssd.estimatedPrefillTokensSaved(
                    promptTokens: promptTokens, cacheScope: cacheScope)
                    > (residentPrefixCandidate?.prefillTokensSaved ?? 0)
        {
            let stageStart = SuspendingClock.now
            let stageResult = await ssd.stage(
                requestID: prefixCacheReceiptID,
                promptTokens: promptTokens,
                cacheScope: cacheScope)
            profile?.markDuration(.ssdStage, start: stageStart)
            ssdStaged = stageResult.staged
            ssdReuseAttempted = stageResult.staged
            usageSignal?.record(stageResult: stageResult)
            if case .skippedCapacity = stageResult.disposition {
                emitPrefixCacheColdFallback(
                    requestId: id,
                    reason: "stage_capacity",
                    capacityRefusal: true)
            }
        }
        try await checkFirstContentDeadline(
            firstContentDeadline,
            requestID: id,
            sharedKVReserved: false,
            prefixCacheReceiptID: prefixCacheReceiptID,
            ssdStaged: ssdStaged,
            readyReceiptRegistered: readyReceiptRegistered,
            usageSignal: usageSignal)

        // Reserve worst-case contiguous request memory atomically across all
        // resident models. Release on rejection, retirement, or pump terminal.
        // Paged requests use the engine's page ledger: the whole pool becomes
        // MLX-active at first admission, so reserving each row here would count
        // those bytes twice. Until then its grant is logical, as for idle
        // contiguous slots; every reservation rechecks live headroom.
        var sharedKVReserved = false
        if kvBackendKind == .contiguous, let kvBudget,
            (kvBytesPerToken > 0 || fixedRequestBytes > 0), cbv2Request.maxTokens > 0
        {
            sharedKVReserved = await reserveSharedRequestBytes(
                budget: kvBudget, requestID: id, tokenCount: worstCaseTokens,
                profile: profile)
            try await checkFirstContentDeadline(
                firstContentDeadline,
                requestID: id,
                sharedKVReserved: sharedKVReserved,
                prefixCacheReceiptID: prefixCacheReceiptID,
                ssdStaged: ssdStaged,
                readyReceiptRegistered: readyReceiptRegistered,
                usageSignal: usageSignal)
            if !sharedKVReserved, ssdStaged, let prefixCacheReceiptID {
                // Optional adoption may be the only reason R no longer fits:
                // retire S synchronously, then retry the full cold request R.
                await abandonPrefixStaging(requestID: prefixCacheReceiptID)
                ssdStaged = false
                try await checkFirstContentDeadline(
                    firstContentDeadline,
                    requestID: id,
                    sharedKVReserved: false,
                    prefixCacheReceiptID: prefixCacheReceiptID,
                    ssdStaged: false,
                    readyReceiptRegistered: readyReceiptRegistered,
                    usageSignal: usageSignal)
                sharedKVReserved = await reserveSharedRequestBytes(
                    budget: kvBudget, requestID: id, tokenCount: worstCaseTokens,
                profile: profile)
                try await checkFirstContentDeadline(
                    firstContentDeadline,
                    requestID: id,
                    sharedKVReserved: sharedKVReserved,
                    prefixCacheReceiptID: prefixCacheReceiptID,
                    ssdStaged: false,
                    readyReceiptRegistered: readyReceiptRegistered,
                    usageSignal: usageSignal)
                if sharedKVReserved {
                    emitPrefixCacheColdFallback(
                        requestId: id,
                        reason: "shared_kv_capacity",
                        capacityRefusal: true)
                }
            }
            guard sharedKVReserved else {
                if ssdReuseAttempted {
                    emitPrefixCacheColdFallback(
                        requestId: id,
                        reason: "shared_kv_capacity",
                        capacityRefusal: true)
                }
                if let prefixCacheReceiptID {
                    if ssdStaged {
                        await abandonPrefixStaging(requestID: prefixCacheReceiptID)
                    }
                    if readyReceiptRegistered {
                        discardPrefixReadyReceipt(requestID: prefixCacheReceiptID)
                    }
                }
                usageSignal?.finalizeLookup(
                    failure: .capacity,
                    fallbackTier: prefixCacheFallbackTier)
                continuation.yield(.error(
                    "token_budget_exhausted: request requires \(worstCaseTokens) tokens "
                        + "but the shared KV budget has no headroom"))
                continuation.finish()
                return stream
            }
        }

        // Expiry is authoritative even when projection policy will fail open.
        // This is the final check after every provider-owned suspension.
        try await checkFirstContentDeadline(
            firstContentDeadline,
            requestID: id,
            sharedKVReserved: sharedKVReserved,
            prefixCacheReceiptID: prefixCacheReceiptID,
            ssdStaged: ssdStaged,
            readyReceiptRegistered: readyReceiptRegistered,
            usageSignal: usageSignal)

        // Snapshot queue isolation at the exact engine-submit boundary. The
        // current provider request is already in `pendingSubmissionIDs`; every
        // other active or pending row disqualifies this sample.
        disqualifyOverlappedPrefillSamples()
        let isolatedPrefillSampleEligible =
            isIsolatedPrefillSubmitBoundary(currentProviderRequestID: id)

        // Reserve the deterministic or monotonic ID before any admission
        // suspension. EngineV2Bridge+Identity defines collision handling.
        let cbv2Id = mintEngineRequestId(
            seed: cbv2Request.sampling.seed, promptTokens: promptTokens)
        cbv2Request.id = cbv2Id
        let engineRequest = cbv2Request
        pendingEngineIDs.insert(cbv2Id)
        idMap[id] = cbv2Id
        defer {
            if !retirementTransfer.isClaimed {
                pendingEngineIDs.remove(cbv2Id)
                if active[id] == nil, idMap[id] == cbv2Id {
                    idMap.removeValue(forKey: id)
                }
            }
        }

        // Hoisted so the profiler can name the deadline mode; pure function of
        // bridge state, no suspension between here and the submit below.
        let deadlineAdmission = firstTokenDeadlineAdmission(
            deadline: firstContentDeadline,
            isMultimodal: multimodal != nil)
        if let profile {
            // Profiler engine-submit snapshot: ONE lock for the stamp and the
            // whole occupancy posture at the submit boundary.
            let snapshot = capacitySnapshot()
            let queuedOthers = max(0, queuedPrefillTokens - promptTokens.count)
            let deadlineMode: DeadlineMode
            if firstContentDeadline == nil {
                deadlineMode = .none
            } else if deadlineAdmission != nil {
                deadlineMode = .projected
            } else {
                deadlineMode = .legacy
            }
            let mtpActive = mtpActivationStatus.active
            let cap = partialPrefillCap
            profile.update { f, now in
                f.mark(.engineSubmit, offsetUs: now)
                f.set(.runningAtAdmit, Int64(snapshot.activeRequests))
                f.set(.waitingAtAdmit, Int64(snapshot.waitingRequests))
                f.set(.kvBytesInUseAtAdmit, Int64(snapshot.kvBytesInUse))
                f.set(.kvBytesCapacity, Int64(snapshot.kvBytesCapacity))
                f.set(.stepsAtSubmit, Int64(snapshot.stepsExecuted))
                f.set(.queuedPrefillTokensAtAdmit, Int64(queuedOthers))
                f.set(.mtpActive, mtpActive)
                if let cap { f.set(.partialPrefillCap, Int64(cap)) }
                f.deadlineMode = deadlineMode
            }
        }

        let events: AsyncStream<CBv2Event>
        // Ordinary submission registers synchronously; atomic submission
        // replaces this with the engine-queue commit instant returned by the
        // admission transaction.
        var engineAdmittedAt = ContinuousClock.now
        guard let engine = ownedEngine else {
            await releasePreSubmitResources(
                requestID: id,
                sharedKVReserved: sharedKVReserved,
                prefixCacheReceiptID: prefixCacheReceiptID,
                ssdStaged: ssdStaged,
                readyReceiptRegistered: readyReceiptRegistered,
                usageSignal: usageSignal,
                failure: .policy)
            continuation.yield(.error("request queue full: engine is shutting down"))
            continuation.finish()
            return stream
        }
        do {
            if let admission = deadlineAdmission {
                // The engine's serialized closure compares projection against
                // this same absolute deadline. A second task-group race would
                // cancel after commit and hide the generation-bound retirement
                // handle needed to transfer resource ownership safely.
                let result = try await engine.submit(
                    engineRequest,
                    firstTokenDeadline: admission)
                switch result {
                case .admitted(let stream, let projectedWork, let admittedAt, let retirement):
                    if Task.isCancelled || pendingCancellationIDs.contains(id) {
                        engine.cancel(cbv2Id)
                        // Admitted, then torn down: an in-flight engine step
                        // may already have produced a token before the cancel
                        // was processed, so `tokens_after_cancel` is OMITTED
                        // here (never a fabricated 0 — see
                        // `recordCancelledBeforeGeneration`).
                        transferPreSubmitRetirement(
                            retirementTransfer,
                            requestID: id,
                            engineID: cbv2Id,
                            stream: stream,
                            retirement: retirement,
                            sharedKVReserved: sharedKVReserved,
                            prefixCacheReceiptID: prefixCacheReceiptID,
                            ssdStaged: ssdStaged,
                            readyReceiptRegistered: readyReceiptRegistered,
                            usageSignal: usageSignal,
                            failure: .policy)
                        throw CancellationError()
                    }
                    do {
                        try firstContentDeadline?.check()
                    } catch {
                        engine.cancel(cbv2Id)
                        // Admission committed at the deadline boundary. Keep
                        // provider-global reservations until the generation-
                        // bound engine acknowledgement proves the row and KV
                        // ownership are gone. A watchdog terminal alone is not
                        // that acknowledgement.
                        transferPreSubmitRetirement(
                            retirementTransfer,
                            requestID: id,
                            engineID: cbv2Id,
                            stream: stream,
                            retirement: retirement,
                            sharedKVReserved: sharedKVReserved,
                            prefixCacheReceiptID: prefixCacheReceiptID,
                            ssdStaged: ssdStaged,
                            readyReceiptRegistered: readyReceiptRegistered,
                            usageSignal: usageSignal,
                            failure: .capacity)
                        throw error
                    }
                    events = stream
                    engineAdmittedAt = admittedAt
                    if let profile {
                        // The engine's commit instant is on the deadline
                        // (continuous) clock: convert into the suspending
                        // anchor's domain (µs window, no sleep possible) and
                        // clamp ≥ engine_submit for the wire order invariant.
                        let admittedOffset = profile.offsetUs(
                            of: profile.suspendingInstant(fromContinuous: admittedAt))
                        let remainingUs = firstContentDeadline.map {
                            RequestProfileBuilder.budgetRemainingUs(
                                $0.remainingDuration(now: admittedAt))
                        }
                        profile.update { f, _ in
                            f.mark(.engineAdmitted,
                                   offsetUs: max(admittedOffset, f.offset(.engineSubmit) ?? 0))
                            if case .bounded(let work, let serviceDuration) = projectedWork {
                                f.set(.projectedPrefillTokens, Int64(work.prefillTokens))
                                f.set(.projectedDecodeTokens, Int64(work.decodeTokens))
                                f.set(.projectedServiceUs,
                                      RequestProfileBuilder.microseconds(serviceDuration))
                            }
                            if let remainingUs { f.set(.budgetRemainingAtAdmitUs, remainingUs) }
                        }
                    }
                case .deadlineUnreachable:
                    if Task.isCancelled || pendingCancellationIDs.contains(id) {
                        // Refused at admission after a latched cancel: nothing
                        // was generated, record the explicit 0 (see the
                        // `.admitted` teardown above).
                        recordCancelledBeforeGeneration(profile)
                        throw CancellationError()
                    }
                    throw PreContentDeadlineFailure.deadlineUnreachable
                }
            } else {
                // Projection fails open when mode is off, no isolated rate has
                // been measured, or media makes token projection incomplete.
                // Absolute expiry does not: it was checked immediately above.
                events = try engine.submit(engineRequest)
                if let profile {
                    // Evaluated AFTER the submit returned: the deadline may
                    // have expired meanwhile, hence the zero clamp.
                    let remainingUs = firstContentDeadline.map {
                        RequestProfileBuilder.budgetRemainingUs($0.remainingDuration())
                    }
                    profile.update { f, now in
                        f.mark(.engineAdmitted, offsetUs: max(now, f.offset(.engineSubmit) ?? 0))
                        if let remainingUs { f.set(.budgetRemainingAtAdmitUs, remainingUs) }
                    }
                }
            }
        } catch let cancellation as CBv2FirstTokenAdmissionCancellation {
            engine.cancel(cbv2Id)
            // Post-admission cancellation: same rule as the `.admitted`
            // teardown above — the field stays absent.
            transferPreSubmitRetirement(
                retirementTransfer,
                requestID: id,
                engineID: cbv2Id,
                stream: cancellation.stream,
                retirement: cancellation.retirement,
                sharedKVReserved: sharedKVReserved,
                prefixCacheReceiptID: prefixCacheReceiptID,
                ssdStaged: ssdStaged,
                readyReceiptRegistered: readyReceiptRegistered,
                usageSignal: usageSignal,
                failure: .policy)
            throw CancellationError()
        } catch {
            // No event pump owns rejected submissions. Release once here unless
            // a committed generation transferred ownership to retirement.
            if !retirementTransfer.isClaimed {
                await releasePreSubmitResources(
                    requestID: id,
                    sharedKVReserved: sharedKVReserved,
                    prefixCacheReceiptID: prefixCacheReceiptID,
                    ssdStaged: ssdStaged,
                    readyReceiptRegistered: readyReceiptRegistered,
                    usageSignal: usageSignal,
                    failure: Self.prefixCacheFailureClass(for: error))
            }
            if let failure = error as? PreContentDeadlineFailure { throw failure }
            if error is CancellationError { throw CancellationError() }
            // Admission failure. The message keeps the canonical
            // `token_budget_exhausted:` prefix contract so
            // `fromSchedulerMessage` classifies it as a retryable capacity
            // error (429/503) exactly as the legacy engine's rejections.
            continuation.yield(.error(EngineV2Translation.admissionErrorMessage(for: error)))
            continuation.finish()
            return stream
        }

        active[id] = ActiveRequestState(
            promptTokens: promptTokens.count,
            maxTokens: cbv2Request.maxTokens,
            isolatedPrefillSampleEligible:
                isolatedPrefillSampleEligible
                && pendingSubmissionIDs.allSatisfy({ $0 == id })
                && pendingEngineIDs.allSatisfy({ $0 == cbv2Id })
                && active.isEmpty,
            submittedAt: engineAdmittedAt,
            profile: profile
        )
        // Wedge instrumentation: the request is now in the engine's hands.
        wedgeMonitor.recordAdmit(now: .now)

        // Emit one allowlisted engagement event for an accepted media request.
        if multimodal != nil {
            emitVisionSubmitTelemetry(requestId: id, mediaKind: mediaKind)
        }

        // The pump owns these resources through engine terminal; each cache
        // manages pending durable publication and receipt retention.
        // Returning from submit is not retirement.
        pumpOwnsPrefixResources = true
        runPump(
            id: id, events: events, continuation: continuation,
            holdsSharedReservation: sharedKVReserved,
            stopSequences: cbv2Request.stopStrings,
            logprobsChannel: logprobsChannel,
            usageSignal: usageSignal,
            prefixCacheReceiptID: prefixCacheReceiptID,
            readyReceiptRegistered: readyReceiptRegistered,
            profile: profile
        )

        let bridge = self
        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination {
                Task { await bridge.cancel(requestId: id) }
            }
        }
        return stream
    }

    private static func prefixCacheFailureClass(
        for error: Error
    ) -> PrefixCacheLookupFailureClass {
        (error is CBv2KVError || error is PreContentDeadlineFailure) ? .capacity : .policy
    }
}
