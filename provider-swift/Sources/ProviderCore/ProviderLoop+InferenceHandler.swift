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
    /// request must be dropped because we're draining.
    private func rejectIfDrainingForUpdate(requestId: String, send: SendHandle) -> Bool {
        guard isDrainingForUpdate else { return false }
        send.send(.inferenceError(
            requestId: requestId,
            error: providerDrainingForUpdateReason,
            statusCode: 503,
            errorReason: nil
        ))
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
        send: SendHandle
    ) async {
        logger.info("Processing inference request: \(requestId)")

        if isShuttingDown {
            send.send(.inferenceError(
                requestId: requestId,
                error: "provider is shutting down",
                statusCode: 503,
                errorReason: nil
            ))
            return
        }

        // Fast-path drain reject (skips decrypt/parse work). Re-checked
        // authoritatively at step 4. See `rejectIfDrainingForUpdate`.
        if rejectIfDrainingForUpdate(requestId: requestId, send: send) { return }

        // 1. Decrypt the request body. Both `ciphertext` and
        // `senderPublicKey` are already base64-decoded by CoordinatorClient,
        // so we hand the raw bytes straight to NodeKeyPair.decrypt.
        guard let senderKey = senderPublicKey, senderKey.count == 32 else {
            logger.error("[\(requestId)] missing or malformed sender public key")
            send.send(.inferenceError(
                requestId: requestId,
                error: "missing or malformed ephemeral_public_key",
                statusCode: 400,
                errorReason: nil
            ))
            return
        }

        let decryptedData: Data
        do {
            decryptedData = try keyPair.decrypt(
                senderPublicKey: senderKey,
                ciphertext: ciphertext
            )
        } catch {
            logger.error("[\(requestId)] decryption failed: \(error)")
            send.send(.inferenceError(
                requestId: requestId,
                error: "decryption failed",
                statusCode: 400,
                errorReason: nil
            ))
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
            logger.error("[\(requestId)] Failed to parse chat request (\(type(of: error)))")
            send.send(.inferenceError(requestId: requestId, error: "invalid request body", statusCode: 400, errorReason: nil))
            return
        }

        // `reasoning_effort` is not part of the upstream
        // `OpenAIChatCompletionRequest` shape, so decode it directly from
        // the request body and thread it into the chat template's render
        // context below (see `MultiModelBatchSchedulerEngine`). gpt-oss /
        // Harmony reads it to set the reasoning budget; other models
        // ignore the extra template variable.
        let reasoningEffort = Self.extractReasoningEffort(from: decryptedData)
        // Per-tenant prefix-cache scope (prompt_cache_key / user). Decoded from
        // the sealed body like reasoning_effort; threaded into the engine so the
        // checkpoint cache is partitioned per consumer. "" ⇒ unscoped.
        let cacheScope = Self.extractCacheScope(from: decryptedData)

        // 3. Fast pre-accept admission check. The coordinator accepts fast and
        // then waits for the first chunk with the full inference timeout, so we
        // must REJECT (status 503) any request we are *certain* we cannot serve
        // — letting the coordinator reroute — rather than accept-then-fail,
        // which it counts as a provider fault (reputation penalty). This mirrors
        // the real load-failure conditions WITHOUT loading anything and is
        // deliberately conservative: when in doubt it admits and lets the
        // post-accept load path below make the final call.
        let modelId = chatRequest.model
        if await fastAdmissionReject(modelId: modelId) {
            logger.warning("[\(requestId)] Pre-accept reject for '\(modelId)': insufficient capacity to load")
            send.send(.inferenceError(
                requestId: requestId,
                error: "insufficient memory to load model '\(modelId)'",
                statusCode: 503,
                errorReason: nil
            ))
            return
        }

        // 4. Authoritative drain re-check. `await fastAdmissionReject` above is a
        // suspension point, so draining could have begun (and the drain snapshot
        // taken) while this request was parked — letting it slip past the early
        // gate. There is NO `await` between this check and the `requestToModel`
        // registration below, so on the actor it is atomic: either we reject now,
        // or the request is counted in `hasInflightWork` before any drain
        // snapshot can miss it.
        if rejectIfDrainingForUpdate(requestId: requestId, send: send) { return }

        // 5. Send inference_accepted
        send.send(.inferenceAccepted(requestId: requestId))

        // 6. Mark the request before loading so concurrent preloads cannot
        // evict the model this accepted request is waiting for.
        requestToModel[requestId] = modelId
        powerAssertion.acquire()
        syncWarmModelState()
        let token = await cancellationRegistry.register(requestId: requestId)

        // 6. Ensure model is loaded. The fast check above only rules out
        // certain failures; this stays authoritative for races (e.g. another
        // request consuming the last slot or free memory between accept and
        // load). Map the failure to a status code so capacity errors reroute
        // (503) and missing models 404 instead of always counting as a fault.
        do {
            try await ensureModelLoaded(modelId: modelId)
        } catch {
            if requestToModel.removeValue(forKey: requestId) != nil {
                powerAssertion.release()
                syncWarmModelState()
                await updateAggregateCapacity()
            }
            await cancellationRegistry.finish(requestId: requestId)
            logger.error("[\(requestId)] Failed to load model '\(modelId)': \(error)")
            let statusCode = Self.loadErrorStatusCode(for: error)
            send.send(.inferenceError(requestId: requestId, error: "model load failed: \(error.localizedDescription)", statusCode: statusCode, errorReason: "model_load"))
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
            logger.error("[\(requestId)] Model '\(modelId)' disappeared after load")
            send.send(.inferenceError(requestId: requestId, error: "model unavailable", statusCode: 500, errorReason: nil))
            return
        }

        modelSlots[modelId]?.lastInferenceAt = .now
        syncWarmModelState()

        // 7. Capture values for the spawned task
        let responsePublicKeyData: Data = senderKey
        let kp = self.keyPair
        let sched = slot.scheduler
        let providerStats = self.stats
        let registry = self.cancellationRegistry
        let signingIdentity = self.signer
        let log = self.logger
        let tokenizer = slot.tokenizer
        // Read modelType from the loaded SLOT, not advertisedModels: the latter
        // goes nil in the hard-swap drop window while the slot is still resident,
        // which would silently fall the reasoning parser back to qwen3 and leak
        // <think> tokens for a Gemma build. The slot carries the type captured at
        // load, so it is correct for startup, prefetched, AND dropped-resident.
        let modelType = slot.modelType
        let slotContainer = slot.container
        let slotIsVLM = slot.isVLM
        // ContinuousBatchingV2 (flag-gated): non-nil only when the slot was
        // loaded with a v2 bridge. The engine below routes text generation
        // through it; nil keeps the legacy scheduler path byte-identical.
        let slotEngineV2 = slot.engineV2

        // 8. Spawn inference task. The streaming pipeline now flows through
        // the upstream `MLXLMServer` library:
        //   - `MultiModelBatchSchedulerEngine` adapts our `BatchScheduler` to
        //     the `MLXServerEngine` contract.
        //   - `MLXOpenAIService.streamChatCompletionFrames` formats SSE
        //     frames (matching the wire shape the coordinator already parses).
        // We encrypt each frame and forward it via `inferenceChunk` exactly
        // as before. The response hash for SE attestation is computed over
        // the assembled assistant text, extracted by parsing each emitted
        // chunk back from its JSON delta.
        let me = self
        let task = Task.detached {
            defer {
                Task {
                    await registry.finish(requestId: requestId)
                    await me.finishInflightRequest(requestId: requestId)
                }
            }

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
                log.error("[\(requestId)] Shared key precomputation failed: \(error)")
                providerStats.incrementChunkEncryptionErrors()
                send.send(.inferenceError(
                    requestId: requestId,
                    error: "response encryption failed",
                    statusCode: 500,
                    errorReason: nil
                ))
                return
            }

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
                    log.error("[\(requestId)] Chunk encryption failed: \(error)")
                    providerStats.incrementChunkEncryptionErrors()
                    send.send(.inferenceError(
                        requestId: requestId,
                        error: "response encryption failed",
                        statusCode: 500,
                        errorReason: nil
                    ))
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

            // Build a single-model engine view bound to the scheduler we
            // already resolved. This keeps the engine constructor's
            // "model not loaded" path unreachable on this code path while
            // still going through the upstream library for SSE encoding.
            let providerEngine = MultiModelBatchSchedulerEngine(
                registryProvider: { @Sendable in
                    [chatRequest.model: .init(
                        scheduler: sched, tokenizer: tokenizer, modelType: modelType,
                        container: slotContainer, isVLM: slotIsVLM,
                        engineV2Bridge: slotEngineV2)]
                },
                ensureLoaded: { _ in },
                reserveModel: { _ in },
                releaseModel: { _ in },
                defaultMaxTokens: Self.schedulerDefaultMaxTokens,
                reasoningEffort: reasoningEffort,
                cacheScope: cacheScope
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
                frames = try await service.streamChatCompletionFrames(
                    request: streamingRequest
                )
            } catch {
                log.error("[\(requestId)] Failed to start stream: \(error)")
                let statusCode = Self.mapInferenceErrorToStatus(error)
                // Classify HERE, where the real `Error` (and its rich
                // `String(describing:)` text) is in scope. For a Harmony
                // TemplateException `error.localizedDescription` collapses to the
                // lossy "(Jinja.TemplateException error 1.)", so the only place we
                // can tell channel-tags from null-bridge from a generic template
                // failure is at this catch (DAR-341). We send ONLY the normalized
                // reason on the wire — never the rich text, which can carry prompt
                // content (E2E privacy).
                let reason = classifyInferenceErrorReason(error)
                if let reason, reason == "jinja_channel_tags" || reason == "jinja_null_bridge" {
                    // Privacy-safe diagnostic: log the OFFENDING message's index +
                    // role only — never its content. `templateMessageDict()` yields
                    // the same dict shape handed to the chat template.
                    if let location = offendingHarmonyMessageLocation(
                        in: streamingRequest.messages.map { $0.templateMessageDict() }
                    ) {
                        log.error(
                            "[\(requestId)] Harmony template render failed reason=\(reason); "
                            + "offending message index=\(location.index) role=\(location.role) "
                            + "(content omitted for privacy)"
                        )
                    } else {
                        log.error(
                            "[\(requestId)] Harmony template render failed reason=\(reason); "
                            + "offending message not located (content omitted for privacy)"
                        )
                    }
                }
                send.send(.inferenceError(
                    requestId: requestId,
                    error: error.localizedDescription,
                    statusCode: statusCode,
                    errorReason: reason
                ))
                return
            }

            await me.updateAggregateCapacity()

            var fullResponseText = ""
            var promptTokens = 0
            var completionTokens = 0
            // Defense-in-depth for the billing-zero leak: count SSE frames that
            // carried visible output. If the usage chunk is lost entirely
            // (parser drift / upstream regression), this is a conservative
            // lower-bound floor for completion tokens so a request that clearly
            // produced output never settles at 0 (which the coordinator would
            // fully refund). MLX streams ~1 token per frame, so this slightly
            // under-counts vs. true tokenization but never bills $0 for work.
            var contentFrameCount = 0
            // Accumulated `reasoning_content` deltas (gpt-oss analysis
            // channel, Qwen3/DeepSeek <think>, Gemma4 channels). Re-tokenized
            // at completion to report an accurate `reasoning_tokens` count —
            // upstream's usage block only carries the total completion count.
            var reasoningText = ""
            var reasoningTokens = 0

            // A cancelled request that already streamed output settles through
            // the completion path below with real usage, not a bare 499 ($0).
            var cancelledMidStream = false
            do {
                for try await frame in frames {
                    if token.isCancelled {
                        log.info("[\(requestId)] Cancelled during generation")
                        cancelledMidStream = true
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
                    if let parsed = Self.parseStreamChunk(frame) {
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
                            contentFrameCount += 1
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
                                frameToEmit = Self.injectReasoningTokens(
                                    into: frame, reasoningTokens: reasoningTokens
                                )
                            }
                        }
                    }
                    if !emitSSE(frameToEmit) { return }
                }
            } catch {
                // Cancellation can throw here or end the stream as a clean
                // nil-end (caught after the loop); both settle as a cancel.
                if error is CancellationError || token.isCancelled {
                    log.info("[\(requestId)] Cancelled while waiting on next frame")
                    cancelledMidStream = true
                } else {
                    log.error("[\(requestId)] Generation error: \(error)")
                    if Self.hasVisibleStreamOutput(
                        contentFrameCount: contentFrameCount,
                        fullResponseText: fullResponseText
                    ) {
                        providerStats.incrementGenerationErrorsAfterOutput()
                    }
                    if Self.isStreamClosedWithoutTerminal(error) {
                        providerStats.incrementStreamClosedWithoutTerminal()
                    }
                    let statusCode = Self.mapInferenceErrorToStatus(error)
                    // Mid-stream generation error. Left unclassified (nil): the
                    // Harmony channel-tags / null-bridge template failures surface
                    // at stream START (see the catch below), not here.
                    send.send(.inferenceError(
                        requestId: requestId,
                        error: error.localizedDescription,
                        statusCode: statusCode,
                        errorReason: nil
                    ))
                    return
                }
            }
            if token.isCancelled { cancelledMidStream = true }

            if cancelledMidStream {
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

                let partialUsage = StreamedGenerationUsage(
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    reasoningTokens: reasoningTokens,
                    contentFrameCount: contentFrameCount,
                    deliveredCompletionTokenFloor: tokenizer.inner.encode(
                        text: fullResponseText, addSpecialTokens: false
                    ).count,
                    hasVisibleOutput: Self.hasVisibleStreamOutput(
                        contentFrameCount: contentFrameCount,
                        fullResponseText: fullResponseText
                    )
                )
                let terminal = partialUsage.cancelledTerminal(promptTokenFloor: Self.promptTokenFloor(
                    request: streamingRequest,
                    tokenizer: tokenizer,
                    reasoningEffort: reasoningEffort
                ))
                guard case .complete(let settledUsage) = terminal else {
                    // Cancelled with nothing delivered: 499 so the coordinator refunds.
                    providerStats.incrementCancellationsBeforeOutput()
                    send.send(.inferenceError(
                        requestId: requestId,
                        error: "request cancelled",
                        statusCode: 499,
                        errorReason: nil
                    ))
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
                        reasoningEffort: reasoningEffort
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
            }

            if cancelledMidStream {
                providerStats.incrementCancellationsPartialComplete()
            }

            // Update stats
            providerStats.incrementRequestsServed()
            providerStats.addTokensGenerated(UInt64(max(completionTokens, 0)))

            // Update state
            await me.updateAggregateCapacity()

            // Send completion
            let attestation = computeResponseAttestation(
                identity: signingIdentity,
                requestId: requestId,
                completionTokens: UInt64(max(completionTokens, 0)),
                responseBody: fullResponseText
            )
            let usageInfo = UsageInfo(
                promptTokens: UInt64(max(0, promptTokens)),
                completionTokens: UInt64(max(0, completionTokens)),
                reasoningTokens: UInt64(max(0, reasoningTokens))
            )
            send.send(.inferenceComplete(
                requestId: requestId,
                usage: usageInfo,
                seSignature: attestation.signature,
                responseHash: attestation.hash
            ))

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
