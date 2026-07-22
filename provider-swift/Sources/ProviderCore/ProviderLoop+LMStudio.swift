import Foundation

private struct LMStudioRelayEncryptionError: Error {}

private let lmStudioActivePollNanoseconds: UInt64 = 2_000_000_000
private let lmStudioIdlePollNanoseconds: UInt64 = 10_000_000_000

extension ProviderLoop {
    internal func startLMStudioMonitor(send: SendHandle) {
        lmStudioMonitorTask?.cancel()
        lmStudioMonitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshLMStudioModels(send: send)
                let interval = await self.lmStudioPollIntervalNanoseconds()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func lmStudioPollIntervalNanoseconds() -> UInt64 {
        lmStudioModels.isEmpty
            ? lmStudioIdlePollNanoseconds
            : lmStudioActivePollNanoseconds
    }

    internal func refreshLMStudioModels(send: SendHandle, force: Bool = false) async {
        let discovered: [LMStudioLoadedModel]
        do {
            discovered = try await lmStudioClient.loadedModels()
        } catch {
            // LM Studio is optional. If it disappears, remove any models it
            // previously exposed; otherwise stay silent.
            if lmStudioModels.isEmpty { return }
            discovered = []
        }

        var next: [String: LMStudioLoadedModel] = [:]
        for model in discovered {
            next[model.darkbloomID] = model
        }
        guard force || next != lmStudioModels else { return }
        lmStudioModels = next
        let models = next.values
            .sorted { $0.darkbloomID < $1.darkbloomID }
            .map(\.modelInfo)
        send.send(.lmStudioModelsUpdate(models: models))
        await updateAggregateCapacity()
    }

    internal func handleLMStudioInference(
        requestId: String,
        requestBody: Data,
        senderKey: Data,
        model: LMStudioLoadedModel,
        token: InferenceCancellationToken,
        lookupReceiptFinalizer: PrefixCacheLookupReceiptFinalizer,
        send: SendHandle
    ) async {
        requestToModel[requestId] = model.darkbloomID
        powerAssertion.acquire()
        await updateAggregateCapacity()
        send.send(.inferenceAccepted(requestId: requestId))

        let client = lmStudioClient
        let keyPair = self.keyPair
        let stats = self.stats
        let signer = self.signer
        let registry = self.cancellationRegistry
        let log = self.logger
        let me = self

        let task = Task.detached {
            defer {
                lookupReceiptFinalizer.finalize(failure: .policy)
                Task {
                    await registry.finish(requestId: requestId)
                    await me.finishInflightRequest(requestId: requestId)
                }
            }

            let sharedKey: Data
            do {
                sharedKey = try keyPair.precomputeSharedKey(recipientPublicKey: senderKey)
            } catch {
                stats.incrementChunkEncryptionErrors()
                lookupReceiptFinalizer.sendTerminal(
                    .inferenceError(
                        requestId: requestId,
                        error: "response encryption failed",
                        statusCode: 500,
                        errorReason: nil),
                    fallbackFailure: .policy,
                    send: send)
                return
            }

            var fullResponseText = ""
            var promptTokens = 0
            var completionTokens = 0
            var contentFrameCount = 0
            var deliveredOutput = false

            do {
                try await client.streamChatCompletion(
                    body: requestBody,
                    instanceID: model.instanceID
                ) { frame in
                    if token.isCancelled { throw CancellationError() }
                    if let parsed = Self.parseStreamChunk(frame) {
                        var frameHasOutput = false
                        if let content = parsed.contentDelta, !content.isEmpty {
                            fullResponseText += content
                            frameHasOutput = true
                        }
                        if let reasoning = parsed.reasoningDelta, !reasoning.isEmpty {
                            fullResponseText += reasoning
                            frameHasOutput = true
                        }
                        if let toolCalls = parsed.toolCallsDelta, !toolCalls.isEmpty {
                            fullResponseText += Self.encodeToolCallsForHash(toolCalls)
                            frameHasOutput = true
                        }
                        if frameHasOutput {
                            deliveredOutput = true
                            contentFrameCount += 1
                        }
                        if let usage = parsed.usage {
                            promptTokens = usage.promptTokens
                            completionTokens = usage.completionTokens
                        }
                    }

                    let encrypted: EncryptedPayload
                    do {
                        encrypted = try keyPair.encryptPayloadFast(
                            sharedKey: sharedKey,
                            plaintext: Data(frame.utf8)
                        )
                    } catch {
                        throw LMStudioRelayEncryptionError()
                    }
                    send.sendChunk(.inferenceChunk(
                        requestId: requestId,
                        data: "",
                        encryptedData: encrypted
                    ))
                }
            } catch {
                if error is CancellationError || token.isCancelled {
                    if !deliveredOutput {
                        stats.incrementCancellationsBeforeOutput()
                        lookupReceiptFinalizer.sendTerminal(
                            .inferenceError(
                                requestId: requestId,
                                error: "request cancelled",
                                statusCode: 499,
                                errorReason: nil),
                            fallbackFailure: .policy,
                            send: send)
                        return
                    }
                    stats.incrementCancellationsPartialComplete()
                } else if error is LMStudioRelayEncryptionError {
                    stats.incrementChunkEncryptionErrors()
                    lookupReceiptFinalizer.sendTerminal(
                        .inferenceError(
                            requestId: requestId,
                            error: "response encryption failed",
                            statusCode: 500,
                            errorReason: nil),
                        fallbackFailure: .policy,
                        send: send)
                    return
                } else {
                    let status = (error as? LMStudioClientError)?.statusCode ?? 502
                    log.warning("[\(requestId)] LM Studio inference failed (\(type(of: error)))")
                    lookupReceiptFinalizer.sendTerminal(
                        .inferenceError(
                            requestId: requestId,
                            error: status == 502 ? "LM Studio is unavailable" : "LM Studio rejected the request",
                            statusCode: status,
                            errorReason: nil),
                        fallbackFailure: status == 503 ? .capacity : .policy,
                        send: send)
                    return
                }
            }

            if completionTokens == 0 && contentFrameCount > 0 {
                completionTokens = contentFrameCount
            }
            stats.incrementRequestsServed()
            stats.addTokensGenerated(UInt64(max(0, completionTokens)))
            let attestation = computeResponseAttestation(
                identity: signer,
                requestId: requestId,
                completionTokens: UInt64(max(0, completionTokens)),
                responseBody: fullResponseText
            )
            lookupReceiptFinalizer.sendTerminal(
                .inferenceComplete(
                    requestId: requestId,
                    usage: UsageInfo(
                        promptTokens: UInt64(max(0, promptTokens)),
                        completionTokens: UInt64(max(0, completionTokens))
                    ),
                    stopSequence: nil,
                    seSignature: attestation.signature,
                    responseHash: attestation.hash),
                fallbackFailure: .policy,
                send: send)
        }

        inflightTasks[requestId] = task
        if completedBeforeTaskRegistration.remove(requestId) != nil {
            inflightTasks.removeValue(forKey: requestId)
        }
    }
}
