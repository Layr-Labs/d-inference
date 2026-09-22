import Foundation
import MLXDecisions

extension ProviderLoop {
    static func isSystemOneRequest(_ data: Data) -> Bool {
        struct Envelope: Decodable { let endpoint: String? }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.endpoint == "/v1/systemone"
    }

    /// Runs native decision inference over the existing encrypted transport.
    /// No chat template, generated text or fabricated completion tokens enter this path.
    func handleSystemOneRequest(
        requestId: String, data: Data, senderKey: Data,
        firstContentDeadline: FirstContentDeadline?, profile: RequestProfileBuilder,
        lookupReceiptFinalizer: PrefixCacheLookupReceiptFinalizer, send: SendHandle
    ) async {
        var transferredToTask = false
        defer {
            if !transferredToTask {
                lookupReceiptFinalizer.finalize(failure: .policy)
                inflightProfiles.removeValue(forKey: requestId)
                completedBeforeTaskRegistration.remove(requestId)
            }
        }
        func fail(_ failure: InferenceFailure) {
            lookupReceiptFinalizer.sendTerminal(
                .inferenceError(requestId: requestId, failure: failure, profile: profile),
                fallbackFailure: failure.code == .capacity ? .capacity : .policy, send: send)
        }
        let request: SystemOneRequest
        do { request = try SystemOneRequest(data: data) }
        catch {
            let status: UInt16 = if case LayaError.invalidJSON = error { 400 } else { 422 }
            fail(InferenceFailure(code: .invalidRequest, statusCode: status)); return
        }
        profile.mark(.parsed)
        let modelId = request.model
        guard advertisedModels[modelId]?.systemOne == true else {
            fail(InferenceFailure(code: .modelUnavailable, statusCode: 404)); return
        }
        // A cancelled GPU call retains its own owner until evaluation exits.
        // Admission counts that owner as busy; it cannot grow an actor mailbox.
        guard decisionRequestOwners.isEmpty,
            !(await fastAdmissionReject(modelId: modelId)) else {
            fail(InferenceFailure(code: .capacity, statusCode: 503, errorReason: .capacityBusy)); return
        }
        guard !isShuttingDown, !isDrainingForUpdate, !isReconnectingAfterRetirement,
            !isRefusedByRetirement(modelId), decisionRequestOwners.isEmpty else {
            fail(InferenceFailure(code: .capacity, statusCode: 503, errorReason: .draining)); return
        }
        do { try firstContentDeadline?.check() }
        catch { fail(InferenceFailure(code: .capacity, statusCode: 503, errorReason: .deadlineUnreachable)); return }

        // Reserve before any await so update/drain and competing requests see us.
        decisionRequestOwners[requestId] = modelId
        requestToModel[requestId] = modelId
        powerAssertion.acquire()
        send.send(.inferenceAccepted(requestId: requestId))
        profile.mark(.acceptedSent)
        let token = await cancellationRegistry.register(requestId: requestId)
        do {
            guard requestToModel[requestId] == modelId else { throw CancellationError() }
            try token.checkCancellation()
            profile.mark(.loadWaitStart)
            try await ensureModelLoaded(modelId: modelId)
            profile.mark(.loadWaitEnd)
            try token.checkCancellation()
            guard requestToModel[requestId] == modelId else { throw CancellationError() }
            try firstContentDeadline?.check()
            guard KVHeadroomProbe.hasServeableKVHeadroom(activationReserveBytes: resolvedActivationReserveBytes) else {
                throw InferenceError.modelLoadFailed("Native decision activation headroom unavailable")
            }
        } catch {
            let failure = error is CancellationError
                ? InferenceFailure(code: .cancelled, statusCode: 499, terminalCause: .cancelled)
                : (error is PreContentDeadlineFailure
                    ? InferenceFailure(code: .capacity, statusCode: 503, errorReason: .deadlineUnreachable)
                    : Self.loadInferenceFailure(for: error))
            fail(failure)
            await finishSystemOneRequest(requestId: requestId)
            return
        }
        guard let runtime = decisionSlots[modelId]?.runtime else {
            fail(InferenceFailure(code: .modelUnavailable, statusCode: 503))
            await finishSystemOneRequest(requestId: requestId)
            return
        }
        decisionSlots[modelId]?.lastInferenceAt = .now
        syncWarmModelState()
        await updateAggregateCapacity()
        let me = self, kp = keyPair, identity = signer, providerStats = stats
        profile.mark(.taskSpawned)
        transferredToTask = true
        let task = Task.detached {
            defer {
                lookupReceiptFinalizer.finalize(failure: .policy)
                Task { await me.finishSystemOneRequest(requestId: requestId) }
            }
            do {
                try token.checkCancellation()
                try firstContentDeadline?.check()
                let response = try await runtime.predict(request)
                try token.checkCancellation()
                try firstContentDeadline?.check()
                let usage = try Self.systemOneUsage(response)
                let shared = try kp.precomputeSharedKey(recipientPublicKey: senderKey)
                let encrypted = try kp.encryptPayloadFast(sharedKey: shared, plaintext: response)
                let attestation = computeResponseAttestation(
                    identity: identity, requestId: requestId, completionTokens: 0,
                    responseBody: String(decoding: response, as: UTF8.self))
                try token.checkCancellation()
                send.sendChunk(.inferenceChunk(requestId: requestId, data: "", encryptedData: encrypted))
                providerStats.incrementRequestsServed()
                lookupReceiptFinalizer.sendTerminal(
                    .inferenceComplete(requestId: requestId, usage: usage, stopSequence: nil,
                        seSignature: attestation.signature, responseHash: attestation.hash, profile: profile),
                    fallbackFailure: .policy, send: send)
            } catch {
                let failure: InferenceFailure
                if error is CancellationError {
                    failure = InferenceFailure(code: .cancelled, statusCode: 499, terminalCause: .cancelled)
                } else if error is PreContentDeadlineFailure {
                    failure = InferenceFailure(code: .capacity, statusCode: 503, errorReason: .deadlineUnreachable)
                } else if case LayaError.invalidJSON = error {
                    failure = InferenceFailure(code: .invalidRequest, statusCode: 400)
                } else if case LayaError.invalidRequest = error {
                    failure = InferenceFailure(code: .invalidRequest, statusCode: 422)
                } else {
                    failure = InferenceFailure(code: .generationFailure, statusCode: 500)
                }
                lookupReceiptFinalizer.sendTerminal(
                    .inferenceError(requestId: requestId, failure: failure, profile: profile),
                    fallbackFailure: failure.code == .capacity ? .capacity : .policy, send: send)
            }
        }
        inflightTasks[requestId] = task
        if completedBeforeTaskRegistration.remove(requestId) != nil {
            inflightTasks.removeValue(forKey: requestId)
        }
    }

    func finishSystemOneRequest(requestId: String) async {
        if let model = decisionRequestOwners.removeValue(forKey: requestId) {
            decisionSlots[model]?.lastInferenceAt = .now
        }
        await cancellationRegistry.finish(requestId: requestId)
        await finishInflightRequest(requestId: requestId)
    }

    static func systemOneUsage(_ response: Data) throws -> UsageInfo {
        struct Response: Decodable {
            struct Usage: Decodable { let input_tokens: UInt64; let output_tokens: UInt64 }
            let usage: Usage
        }
        let usage = try JSONDecoder().decode(Response.self, from: response).usage
        guard usage.output_tokens == 0, usage.input_tokens > 0, usage.input_tokens <= 32_768 else {
            throw LayaError.invalidRequest("Invalid native decision usage")
        }
        return UsageInfo(promptTokens: usage.input_tokens, completionTokens: 0)
    }
}
