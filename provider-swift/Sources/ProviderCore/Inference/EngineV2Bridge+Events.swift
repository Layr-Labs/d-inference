// Engine event translation, terminal framing, and request resource release.

import Foundation
import MLXLMCommon

extension EngineV2Bridge {
    // MARK: - Event pump (CBv2Event → GenerationEvent)

    func runPump(
        id: String,
        events: AsyncStream<CBv2Event>,
        continuation: AsyncStream<GenerationEvent>.Continuation,
        holdsSharedReservation: Bool,
        stopSequences: [String] = [],
        logprobsChannel: EngineV2LogprobsChannel? = nil,
        usageSignal: EngineV2RequestUsageSignal? = nil,
        prefixCacheReceiptID: CBv2RequestID? = nil,
        readyReceiptRegistered: Bool = false,
        profile: RequestProfileBuilder? = nil
    ) {
        let bridge = self
        usageSignal?.beginTerminalObservation()
        let task = Task {
            await bridge.pump(
                id: id, events: events, continuation: continuation,
                holdsSharedReservation: holdsSharedReservation,
                stopSequences: stopSequences,
                logprobsChannel: logprobsChannel,
                usageSignal: usageSignal,
                prefixCacheReceiptID: prefixCacheReceiptID,
                readyReceiptRegistered: readyReceiptRegistered,
                profile: profile
            )
            await bridge.clearPumpTask(id: id)
        }
        pumpTasks[id] = task
    }

    /// Remove a completed pump's task handle (called from the pump task after
    /// `pump` returns, on every exit path).
    func clearPumpTask(id: String) {
        pumpTasks.removeValue(forKey: id)
    }

    private func pump(
        id: String,
        events: AsyncStream<CBv2Event>,
        continuation: AsyncStream<GenerationEvent>.Continuation,
        holdsSharedReservation: Bool,
        stopSequences: [String] = [],
        logprobsChannel: EngineV2LogprobsChannel? = nil,
        usageSignal: EngineV2RequestUsageSignal? = nil,
        prefixCacheReceiptID: CBv2RequestID? = nil,
        readyReceiptRegistered: Bool = false,
        profile: RequestProfileBuilder? = nil
    ) async {
        // Resolve only after record(usage:) has delivered the lookup callback
        // or teardown has finalized its failure, and owned resources retire.
        defer { usageSignal?.completeTerminalObservation() }
        // NOTE: the shared-budget KV reservation is taken in `submitTokenized`
        // (the pre-engine admission gate), NOT here — the pump only RELEASES
        // it on the terminal/teardown paths below, and ONLY when THIS request
        // took one (`holdsSharedReservation`): an unconditional release could
        // drop a same-keyed reservation owned by a different submission in
        // the pathological duplicate-id corner.
        var sawFirstToken = false
        var sawTerminal = false
        // Replay is only needed when a caller consumes matched-stop metadata.
        let trackStopTokens = usageSignal != nil && !stopSequences.isEmpty
        var generatedTokens: [Int] = []
        // Profiler: pump-LOCAL last-delta instant (one clock read per delta,
        // no lock), written to the profile exactly once at finish.
        var lastDeltaAt: SuspendingClock.Instant?
        eventLoop: for await event in events {
            switch event {
            case .delta(let text, let tokens, let logprobs):
                if profile != nil, !tokens.isEmpty {
                    lastDeltaAt = .now
                }
                // Key first-token on TOKEN count, not text: some tokens
                // (BPE intermediates, specials) detokenize to "" and would
                // otherwise leave the first-token bookkeeping unset.
                if !sawFirstToken, !tokens.isEmpty {
                    sawFirstToken = true
                    recordFirstToken(
                        id: id, emissionTokens: tokens.count, profileNow: lastDeltaAt)
                }
                recordProgress(id: id, newTokens: tokens.count)
                if trackStopTokens {
                    // EngineLoopV2 suppresses stop-token text before the
                    // stop-string holdback sees it. Exclude those raw tokens
                    // from replay too, or an EOS token whose debug rendering
                    // equals a caller sequence would become a false match.
                    for token in tokens where !stopTokenIds.contains(token) {
                        generatedTokens.append(token)
                    }
                }
                // Logprobs passthrough: convert to the OpenAI streaming
                // entry shape and publish to the per-request channel BEFORE
                // yielding the chunk, so by the time the SSE frame carrying
                // this delta's text reaches the frame decorator its entries
                // are already drainable (happens-before via the yield).
                if let logprobsChannel, let logprobs, !logprobs.isEmpty {
                    logprobsChannel.append(
                        EngineV2Translation.sseTokenLogprobs(
                            logprobs,
                            decodeToken: { [inner = tokenizer.inner] id in
                                inner.decode(tokenIds: [id], skipSpecialTokens: false)
                            }
                        )
                    )
                }
                if !text.isEmpty {
                    continuation.yield(.chunk(text))
                }
            case .finished(let reason, let usage):
                #if DEBUG
                if let gate = _testBeforeNativeTerminal {
                    _testBeforeNativeTerminal = nil
                    await gate(usage)
                }
                #endif
                sawTerminal = true
                if reason == .stop || reason == .length {
                    usageSignal?.record(matchedStopSequence: matchedStopSequence(
                        candidates: stopSequences,
                        generatedTokens: generatedTokens
                    ))
                }
                // Out-of-band usage detail (logprobs-channel pattern): the
                // engine's prefix-cache detail has no seat in the shared
                // `GenerationEvent.info` shape, so the frames loop reads it
                // from this per-request signal and splices
                // `usage.prompt_tokens_details.cached_tokens` into the
                // trailing SSE usage chunk. Recorded BEFORE the terminal
                // events are yielded, so it is set by the time any
                // downstream consumer sees the usage frame.
                usageSignal?.record(
                    usage: usage,
                    fallbackTier: prefixCacheFallbackTier)
                ssdPrefixCache?.recordPrefillTokensSaved(
                    usage.prefixCachePrefillTokensSaved)
                emitPrefixReuseTelemetry(requestId: id, usage: usage)
                finishAndEmit(
                    id: id, reason: reason, usage: usage,
                    sawFirstToken: sawFirstToken, continuation: continuation,
                    lastDeltaAt: lastDeltaAt
                )
                break eventLoop
            }
        }
        // Closing without a terminal is a teardown error, including task
        // cancellation while waiting for the engine's next event.
        if !sawTerminal {
            continuation.yield(.error("request stream closed by engine teardown"))
            if !sawFirstToken {
                wedgeMonitor.recordTerminalWithoutFirstToken()
            }
            dropRequest(id: id)
        }
        // Every exit releases only the resources owned by this submission.
        // Staging completion is an idempotent backstop for lookup misses.
        if holdsSharedReservation {
            await kvBudget?.release(requestID: id)
        }
        if let prefixCacheReceiptID {
            ssdPrefixCache?.completeStaging(requestID: prefixCacheReceiptID)
            ssdHybridCheckpointStore?.completeStaging(requestID: prefixCacheReceiptID)
            residentPrefixCacheEvidence?.discard(receiptID: prefixCacheReceiptID)
        }
        if !sawTerminal {
            usageSignal?.finalizeLookup(
                failure: .policy,
                fallbackTier: prefixCacheFallbackTier)
        }
        if readyReceiptRegistered, let prefixCacheReceiptID {
            ssdPrefixCache?.markReadyReceiptTerminal(requestID: prefixCacheReceiptID)
            ssdHybridCheckpointStore?.markReadyReceiptTerminal(requestID: prefixCacheReceiptID)
        }
        continuation.finish()
    }

    /// Preserve finish reasons, billable usage on cancellation, and typed errors.
    private func finishAndEmit(
        id: String,
        reason: CBv2FinishReason,
        usage: CBv2Usage,
        sawFirstToken: Bool,
        continuation: AsyncStream<GenerationEvent>.Continuation,
        lastDeltaAt: SuspendingClock.Instant? = nil
    ) {
        switch reason {
        case .stop, .length:
            let final = recordFinish(id: id, usage: usage, success: true, lastDeltaAt: lastDeltaAt, finishReason: reason)
            // Preserve the v2 engine's truncation signal: `.length` must
            // reach the client as finish_reason "length", not be flattened
            // to "stop" (max_tokens truncation was invisible on v2).
            continuation.yield(.info(
                promptTokens: final.prompt,
                completionTokens: final.completion,
                tokensPerSecond: final.tps,
                finishReason: reason == .length ? "length" : "stop"
            ))
        case .cancelled:
            let final = recordFinish(
                id: id, usage: usage, success: false, lastDeltaAt: lastDeltaAt,
                finishReason: reason)
            // A cancel that did real work emits its usage BEFORE the error
            // so a listener can still bill delivered tokens (legacy abort
            // framing).
            if final.prompt > 0 || final.completion > 0 {
                continuation.yield(.info(
                    promptTokens: final.prompt,
                    completionTokens: final.completion,
                    tokensPerSecond: final.tps,
                    finishReason: nil
                ))
            }
            continuation.yield(.error("request cancelled"))
        case .terminal(let cbCause, let message):
            // Typed platform/engine terminal (a monotonic deadline lease or
            // the step watchdog). Reconcile usage the same way as any other
            // non-natural finish, then carry BOTH the machine-readable cause
            // AND that usage through — instead of flattening the deadline into
            // a generic string with zero usage (the incident behavior).
            let final = recordFinish(
                id: id, usage: usage, success: false, lastDeltaAt: lastDeltaAt,
                finishReason: reason)
            emitInferenceErrorTelemetry(requestId: id)
            if let wireCause = Self.wireTerminalCause(cbCause) {
                continuation.yield(.terminal(
                    cause: wireCause,
                    message: message,
                    promptTokens: final.prompt,
                    completionTokens: final.completion))
            } else {
                // No wire mapping (the `.legacyRequestTimeout` kill-switch, or
                // any future engine cause): fall back to the legacy string
                // shape byte-for-byte — never guess a typed cause.
                continuation.yield(.error(message))
            }
        case .error(let message):
            _ = recordFinish(
                id: id, usage: usage, success: false, lastDeltaAt: lastDeltaAt,
                finishReason: reason)
            emitInferenceErrorTelemetry(requestId: id)
            if message.hasPrefix(CBv2KVError.capacityExhaustedFinishPrefix) {
                // Engine-side TERMINAL capacity exhaustion (the paged pool
                // stayed full through the whole requeue budget). Retryable
                // by definition — the backend is full of other tenants'
                // KV, not broken — so surface the canonical capacity
                // marker (429-class, the OpenRouter never-serve-5xx
                // posture), never an in-band server error.
                continuation.yield(.error(
                    "token_budget_exhausted: KV capacity exhausted after "
                        + "requeues (\(message))"))
            } else {
                continuation.yield(.error(message))
            }
        }
        if !sawFirstToken {
            wedgeMonitor.recordTerminalWithoutFirstToken()
        }
    }

    /// Map an engine terminal cause to its wire vocabulary, or nil when there
    /// is no mapping (the request then falls back to the legacy `.error(String)`
    /// shape — NEVER guess a cause). Only the six lease/watchdog causes have a
    /// wire mapping; `.legacyRequestTimeout` (the rollback kill-switch) and any
    /// future engine case stay untyped, matching the pre-fix behavior exactly.
    private static func wireTerminalCause(
        _ cause: CBv2TerminalCause
    ) -> InferenceTerminalCause? {
        switch cause {
        case .admissionTimeout: return .admissionTimeout
        case .prefillStall: return .prefillStall
        case .decodeStall: return .decodeStall
        case .safetyDeadline: return .safetyDeadline
        case .backpressureTimeout: return .backpressureTimeout
        case .watchdog: return .watchdog
        case .legacyRequestTimeout: return nil
        @unknown default: return nil
        }
    }

    /// Media-through-v2 engagement (v0.7.5; media-kind tagged since
    /// v0.7.5): INFO per engine-accepted image/video request. PRIVACY:
    /// allowlisted operational fields only — the request's media/prompt
    /// content never rides telemetry; `multimodal` is a bare boolean tag
    /// and `media_kind` is one of image/video/mixed.
    func emitVisionSubmitTelemetry(requestId: String, mediaKind: EngineV2MediaKind?) {
        var event = TelemetryEvent(
            source: .provider,
            severity: .info,
            kind: .engineHealth,
            message: "engine_v2: media request served via ContinuousBatchingV2"
        )
        // Filter-at-source, matching the other engine_health builders —
        // every key is allowlisted already; the filter enforces it stays so.
        var fields: [String: AnyCodableValue] = [
            "component": .string("engine"),
            "operation": .string("engine_v2_vision"),
            "backend": .string("engine_v2"),
            "model": .string(modelId),
            "multimodal": .bool(true),
        ]
        if let mediaKind {
            fields["media_kind"] = .string(mediaKind.rawValue)
        }
        event.fields = TelemetryFieldFilter.filter(fields)
        event.requestId = requestId
        emit(event)
    }

    /// PRIVACY: engine-error telemetry carries only allowlisted operational
    /// fields — never the error message (defense in depth against any
    /// engine string that could embed request-adjacent detail).
    func emitInferenceErrorTelemetry(requestId: String) {
        var event = TelemetryEvent(
            source: .provider,
            severity: .error,
            kind: .inferenceError,
            message: "engine_v2: generation failed"
        ).withFields([
            "component": .string("engine"),
            "operation": .string("engine_v2_error"),
            "backend": .string("engine_v2"),
            "model": .string(modelId),
            "error_class": .string("cbv2_engine_error"),
        ])
        event.requestId = requestId
        emit(event)
    }

    /// Route telemetry through the injectable sink (tests) or the shared
    /// client (production). The rule itself lives in `emitEngineHealth` so the
    /// static builders in `EngineV2Config` / `EngineV2SlotFactory`, which have
    /// no bridge to call, cannot drift from it.
    func emit(_ event: TelemetryEvent) {
        emitEngineHealth(event, sink: emitTelemetry)
    }
}
