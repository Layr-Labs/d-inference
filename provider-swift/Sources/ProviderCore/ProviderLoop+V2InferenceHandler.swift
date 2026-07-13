import Foundation
import MLX
import MLXLMCommon
import MLXLMServer

private enum ProtocolV2PrepareError: Error, Sendable {
    case draining
    case modelNotReady
    case capacity
}

private enum V2SessionReadinessResult: Sendable, Equatable {
    case paidReady
    case controlOnly
    case ended
}

/// Deterministic boundary for protocol/persistence integration tests on hosts
/// that cannot execute MLX. Production always passes nil and uses the exact
/// ProviderLoop decrypt/render/tokenize/model-pin path below.
struct ProviderLoopV2InferenceHooks: Sendable {
    let prepare: @Sendable (V2Prepare) async throws -> PreparedInference
    let executor: @Sendable (PreparedInference) throws -> any PreparedInferenceExecutor
}

private actor V2SessionReadiness {
    private var paidReady: Set<ProviderSessionIdentity> = []
    private var controlOnly: Set<ProviderSessionIdentity> = []
    private var ended: Set<ProviderSessionIdentity> = []
    private var waiters:
        [ProviderSessionIdentity:
            [UUID: CheckedContinuation<V2SessionReadinessResult, Never>]] = [:]

    func markReady(
        _ session: ProviderSessionIdentity,
        paidAdmissionAllowed: Bool
    ) {
        guard !ended.contains(session) else { return }
        if paidAdmissionAllowed {
            paidReady.insert(session)
            controlOnly.remove(session)
        } else {
            controlOnly.insert(session)
            paidReady.remove(session)
        }
        let pending =
            waiters.removeValue(forKey: session).map {
                Array($0.values)
            } ?? []
        let result: V2SessionReadinessResult =
            paidAdmissionAllowed ? .paidReady : .controlOnly
        for waiter in pending { waiter.resume(returning: result) }
    }

    func markEnded(_ session: ProviderSessionIdentity) {
        paidReady.remove(session)
        controlOnly.remove(session)
        ended.insert(session)
        let pending =
            waiters.removeValue(forKey: session).map {
                Array($0.values)
            } ?? []
        for waiter in pending { waiter.resume(returning: .ended) }
    }

    func wait(
        _ session: ProviderSessionIdentity
    ) async -> V2SessionReadinessResult {
        if paidReady.contains(session) { return .paidReady }
        if controlOnly.contains(session) { return .controlOnly }
        if ended.contains(session) { return .ended }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .ended)
                } else if paidReady.contains(session) {
                    continuation.resume(returning: .paidReady)
                } else if controlOnly.contains(session) {
                    continuation.resume(returning: .controlOnly)
                } else if ended.contains(session) {
                    continuation.resume(returning: .ended)
                } else {
                    waiters[session, default: [:]][waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    session: session,
                    waiterID: waiterID
                )
            }
        }
    }

    func activeSessions() -> [ProviderSessionIdentity] {
        Array(paidReady.union(controlOnly))
    }

    private func cancelWaiter(
        session: ProviderSessionIdentity,
        waiterID: UUID
    ) {
        guard let waiter = waiters[session]?.removeValue(forKey: waiterID) else {
            return
        }
        if waiters[session]?.isEmpty == true {
            waiters.removeValue(forKey: session)
        }
        waiter.resume(returning: .ended)
    }
}

private actor V2InferenceTaskRegistry {
    private struct Entry {
        let session: ProviderSessionIdentity
        let task: Task<Void, Never>
    }

    private var tasks: [UUID: Entry] = [:]
    private var completedBeforeInsert = Set<UUID>()
    private var closedSessions = Set<ProviderSessionIdentity>()

    func open(session: ProviderSessionIdentity) {
        closedSessions.remove(session)
    }

    func insert(
        _ task: Task<Void, Never>,
        id: UUID,
        session: ProviderSessionIdentity
    ) {
        if completedBeforeInsert.remove(id) != nil {
            return
        }
        tasks[id] = Entry(session: session, task: task)
        if closedSessions.contains(session) {
            task.cancel()
        }
    }

    func remove(id: UUID) {
        if tasks.removeValue(forKey: id) == nil {
            completedBeforeInsert.insert(id)
        }
    }

    func cancelAndWait(session: ProviderSessionIdentity) async {
        closedSessions.insert(session)
        while true {
            let active = tasks.compactMap { id, entry -> (UUID, Task<Void, Never>)? in
                entry.session == session ? (id, entry.task) : nil
            }
            guard !active.isEmpty else { return }
            for (_, task) in active { task.cancel() }
            for (_, task) in active {
                await task.value
            }
            for (id, _) in active {
                tasks.removeValue(forKey: id)
            }
        }
    }

    func cancelAndWait() async {
        closedSessions.formUnion(tasks.values.map(\.session))
        while !tasks.isEmpty {
            let active = Array(tasks)
            for (_, entry) in active { entry.task.cancel() }
            for (_, entry) in active { await entry.task.value }
            for (id, _) in active {
                tasks.removeValue(forKey: id)
            }
        }
        completedBeforeInsert.removeAll()
    }
}

private actor V2ModelLifecycleEmitter {
    private var session: V2NegotiatedSession?
    private var observedRevision: UInt64?
    private var observedModels = Set<String>()

    func activate(
        _ session: V2NegotiatedSession,
        state: ProviderState,
        hashes: [String: String],
        coordinator: CoordinatorClient
    ) async {
        self.session = session
        observedRevision = nil
        observedModels = []
        await emitChanges(
            state: state,
            hashes: hashes,
            coordinator: coordinator
        )
    }

    func end(_ ended: V2NegotiatedSession) {
        guard session == ended else { return }
        session = nil
        observedRevision = nil
        observedModels = []
    }

    func tick(
        state: ProviderState,
        hashes: [String: String],
        coordinator: CoordinatorClient
    ) async {
        await emitChanges(
            state: state,
            hashes: hashes,
            coordinator: coordinator
        )
    }

    private func emitChanges(
        state: ProviderState,
        hashes: [String: String],
        coordinator: CoordinatorClient
    ) async {
        guard let session else { return }
        guard session.capabilities.modelLifecycleEvents else { return }
        let snapshot = state.modelStateSnapshot()
        guard observedRevision != snapshot.revision else { return }
        guard
            await coordinator.sendProtocolV2ModelStateHeartbeat(
                session: session.identity,
                revision: snapshot.revision,
                warmModels: snapshot.warmModels
            )
        else {
            return
        }
        let current = Set(snapshot.warmModels)
        let added = current.subtracting(observedModels).sorted()
        let removed = observedModels.subtracting(current).sorted()
        do {
            for model in added {
                try await coordinator.sendProtocolV2ControlMessage(
                    .modelReady(
                        V2ModelReady(
                            identity: session.identity,
                            model: model,
                            stateRevision: snapshot.revision,
                            weightHash: hashes[model]
                        )))
            }
            for model in removed {
                try await coordinator.sendProtocolV2ControlMessage(
                    .modelGone(
                        V2ModelGone(
                            identity: session.identity,
                            model: model,
                            stateRevision: snapshot.revision,
                            reason: "unloaded"
                        )))
            }
        } catch {
            // Do not commit the revision after a failed event write. The next tick
            // retries the complete snapshot transition.
            return
        }
        observedModels = current
        observedRevision = snapshot.revision
    }
}

extension ProviderLoop {
    internal func runProtocolV2Handlers(
        coordinator: CoordinatorClient,
        send: SendHandle,
        attempts: V2PreparedAttemptCoordinator,
        hooks: ProviderLoopV2InferenceHooks? = nil
    ) async {
        let readiness = V2SessionReadiness()
        let inferenceTasks = V2InferenceTaskRegistry()
        let lifecycle = V2ModelLifecycleEmitter()
        let sessions = await coordinator.protocolV2Sessions()
        let commands = await coordinator.protocolV2Commands()
        let binaries = await coordinator.protocolV2BinaryFrames()

        let sessionTask = Task {
            for await event in sessions {
                switch event {
                case .negotiated(let session):
                    await inferenceTasks.open(session: session.identity)
                    await lifecycle.activate(
                        session,
                        state: state,
                        hashes: liveModelHashes,
                        coordinator: coordinator
                    )
                    do {
                        // Recovery and the first complete replay happen before
                        // readiness is opened to paid prepare.
                        let replays = try await attempts.activate(
                            providerID: session.identity.providerID)
                        for replay in replays {
                            try await coordinator.sendProtocolV2HistoricalTerminal(
                                replay
                            )
                        }
                        let paidAdmissionAllowed =
                            try await attempts.paidAdmissionStatus()
                            .paidAdmissionAllowed
                        await readiness.markReady(
                            session.identity,
                            paidAdmissionAllowed: paidAdmissionAllowed
                        )
                    } catch {
                        logger.error(
                            "Protocol-v2 durable activation failed; paid admission remains closed")
                        // Keep consuming controls so prepare receives a typed capacity
                        // rejection and terminal ACKs can still be retried. New paid work
                        // remains closed for this session because initial replay did not
                        // complete.
                        await readiness.markReady(
                            session.identity,
                            paidAdmissionAllowed: false
                        )
                    }
                case .ended(let session):
                    await readiness.markEnded(session.identity)
                    // Cancel and join accepted controls first. A prepare task can be
                    // outside the composition actor doing model work; joining it before
                    // endSession ensures any late reservation is included in cleanup.
                    await inferenceTasks.cancelAndWait(session: session.identity)
                    await attempts.endSession(session.identity)
                    await lifecycle.end(session)
                }
            }
        }

        let commandTask = Task {
            for await delivery in commands {
                let readinessResult = await readiness.wait(
                    delivery.session.identity)
                guard readinessResult != .ended else {
                    continue
                }
                let taskID = UUID()
                let task = Task { [weak self] in
                    guard let self else { return }
                    await self.handleProtocolV2Command(
                        delivery.command,
                        session: delivery.session,
                        attempts: attempts,
                        coordinator: coordinator,
                        send: send,
                        inferenceTasks: inferenceTasks,
                        readiness: readiness,
                        hooks: hooks,
                        paidAdmissionAllowed: readinessResult == .paidReady
                    )
                    await inferenceTasks.remove(id: taskID)
                }
                await inferenceTasks.insert(
                    task,
                    id: taskID,
                    session: delivery.session.identity
                )
            }
        }

        let binaryTask = Task {
            // V2 prepare is intentionally inline as an EncryptedPayload object.
            // Drain negotiated binary input and reject it at the source instead
            // of leaving an unconsumed stream/backpressure ambiguity.
            for await delivery in binaries {
                guard
                    await readiness.wait(delivery.session.identity) != .ended
                else {
                    continue
                }
                send.send(
                    .structuredError(
                        V2StructuredError(
                            identity: delivery.frame.header.attemptIdentity,
                            errorClass: .invalidRequest,
                            message: "binary prepare payloads are not accepted"
                        )))
            }
        }

        let maintenanceTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
                _ = await attempts.reapTerminalBindings()
                await lifecycle.tick(
                    state: state,
                    hashes: liveModelHashes,
                    coordinator: coordinator
                )
                // There is no fragile "sent" bit. Replay every durable
                // terminal until an exact ACK removes it.
                try? await sendPendingProtocolV2Terminals(
                    attempts: attempts,
                    coordinator: coordinator
                )
            }
        }

        await withTaskCancellationHandler {
            await sessionTask.value
        } onCancel: {
            sessionTask.cancel()
            commandTask.cancel()
            binaryTask.cancel()
            maintenanceTask.cancel()
        }
        commandTask.cancel()
        binaryTask.cancel()
        maintenanceTask.cancel()
        await commandTask.value
        await binaryTask.value
        await maintenanceTask.value
        // A client shutdown finishes the session stream before its connection
        // teardown can necessarily publish `.ended`. Fence and release every
        // session that was still active when this handler was cancelled.
        for session in await readiness.activeSessions() {
            await readiness.markEnded(session)
            await inferenceTasks.cancelAndWait(session: session)
            await attempts.endSession(session)
        }
        await inferenceTasks.cancelAndWait()
    }

    private func handleProtocolV2Command(
        _ command: V2CoordinatorControlMessage,
        session: V2NegotiatedSession,
        attempts: V2PreparedAttemptCoordinator,
        coordinator: CoordinatorClient,
        send: SendHandle,
        inferenceTasks: V2InferenceTaskRegistry,
        readiness: V2SessionReadiness,
        hooks: ProviderLoopV2InferenceHooks?,
        paidAdmissionAllowed: Bool
    ) async {
        switch command {
        case .prepare(let message):
            do {
                guard paidAdmissionAllowed else {
                    throw V2PreparedAttemptCoordinatorError.paidAdmissionStopped
                }
                guard
                    try V2Prepare.digest(of: message.encryptedBody)
                        == message.requestDigest
                else {
                    throw PreparedLeaseError.conflictingDuplicate
                }
                let digest = message.requestDigest.bytes.base64EncodedString()
                if let existing = try await attempts.preparedLease(
                    identity: message.identity,
                    requestDigest: digest,
                    modelID: message.model
                ) {
                    send.send(
                        .prepared(
                            protocolV2Prepared(
                                lease: existing,
                                requestDigest: message.requestDigest
                            )))
                    return
                }
                try await attempts.validatePrepareAllowed(
                    identity: message.identity)
                let inference: PreparedInference
                let executor: any PreparedInferenceExecutor
                if let hooks {
                    inference = try await hooks.prepare(message)
                    executor = try hooks.executor(inference)
                } else {
                    inference = try await prepareProtocolV2Inference(message)
                    executor = try protocolV2Executor(for: inference)
                }
                let lease = try await attempts.prepare(
                    inference: inference,
                    expiresAt: Date().addingTimeInterval(15),
                    using: executor
                )
                send.send(
                    .prepared(
                        protocolV2Prepared(
                            lease: lease,
                            requestDigest: message.requestDigest
                        )))
            } catch {
                sendProtocolV2Error(error, identity: message.identity, send: send)
            }

        case .start(let message):
            do {
                switch try await attempts.start(identity: message.identity) {
                case .alreadyStarted:
                    try await coordinator.sendProtocolV2ControlMessage(
                        .startAck(V2StartAck(identity: message.identity))
                    )
                    try await sendPendingProtocolV2Terminals(
                        attempts: attempts,
                        coordinator: coordinator
                    )
                case .started(let prepared, let execution):
                    // This ACK is after funded-start fsync and successful engine
                    // submit. Awaiting the control write also prevents the
                    // direct binary path from overtaking start_ack on the wire.
                    do {
                        try await coordinator.sendProtocolV2ControlMessage(
                            .startAck(V2StartAck(identity: message.identity))
                        )
                    } catch {
                        _ = try? await attempts.cancelUndeliveredStart(
                            identity: message.identity)
                        throw error
                    }
                    let taskID = UUID()
                    let task = Task { [weak self] in
                        guard let self else { return }
                        await self.streamProtocolV2Inference(
                            prepared: prepared,
                            execution: execution,
                            session: session,
                            attempts: attempts,
                            coordinator: coordinator,
                            send: send
                        )
                        await inferenceTasks.remove(id: taskID)
                    }
                    await inferenceTasks.insert(
                        task,
                        id: taskID,
                        session: session.identity
                    )
                }
            } catch {
                sendProtocolV2Error(error, identity: message.identity, send: send)
                try? await sendPendingProtocolV2Terminals(
                    attempts: attempts,
                    coordinator: coordinator
                )
            }

        case .queryAttempt(let message):
            do {
                let status = try await attempts.attemptStatus(
                    identity: message.identity)
                try await coordinator.sendProtocolV2ControlMessage(
                    .attemptStatus(status))
                if status.state == .terminal {
                    try await sendPendingProtocolV2Terminals(
                        attempts: attempts,
                        coordinator: coordinator
                    )
                }
            } catch {
                sendProtocolV2Error(error, identity: message.identity, send: send)
            }

        case .abort(let message):
            do {
                _ = try await attempts.abort(
                    identity: message.identity, reason: message.reason)
                send.send(.abortAck(V2AbortAck(identity: message.identity)))
            } catch {
                sendProtocolV2Error(error, identity: message.identity, send: send)
            }

        case .cancel(let message):
            do {
                _ = try await attempts.cancel(identity: message.identity)
                send.send(.cancelAck(V2CancelAck(identity: message.identity)))
            } catch {
                sendProtocolV2Error(error, identity: message.identity, send: send)
            }

        case .terminalAck(let acknowledgement):
            do {
                try await attempts.acknowledge(acknowledgement)
            } catch {
                // ACK conflict/mismatch is a security event. Never echo a
                // success ACK and never delete the durable terminal.
                do {
                    try await coordinator.sendProtocolV2HistoricalStructuredError(
                        V2StructuredError(
                            identity: acknowledgement.identity,
                            errorClass: .security,
                            message: "terminal acknowledgement conflict"
                        ))
                } catch {
                    logger.warning(
                        "Protocol-v2 terminal ACK conflict response could not be sent")
                }
            }

        case .coordinatorReplayFence(let proof):
            do {
                let verifier = try session.replayFenceVerifier()
                _ = try await attempts.expireAbortTombstones(
                    using: proof,
                    verifiedBy: verifier
                )
                guard let proofID = ProtocolV2UUID(proof.proofID),
                    let providerID = ProviderID(proof.providerID),
                    let generation = ProviderProcessGenerationID(
                        proof.providerProcessGeneration)
                else {
                    throw AttemptTombstoneError.invalidReplayFenceProof
                }
                try await coordinator.sendProtocolV2ControlMessage(
                    .replayFenceAck(
                        V2ReplayFenceAck(
                            proofID: proofID,
                            providerID: providerID,
                            providerProcessGeneration: generation
                        )))
                let paidAdmissionAllowed =
                    try await attempts.paidAdmissionStatus().paidAdmissionAllowed
                await readiness.markReady(
                    session.identity,
                    paidAdmissionAllowed: paidAdmissionAllowed
                )
            } catch {
                // A malformed signature is never an expiration authority. Keep every
                // tombstone and the current admission state unchanged.
                logger.warning(
                    "Rejected protocol-v2 coordinator replay-fence proof: \(error)")
            }
        }
    }

    private func protocolV2Prepared(
        lease: PreparedLease,
        requestDigest: ProtocolV2Digest
    ) -> V2Prepared {
        V2Prepared(
            identity: lease.identity,
            model: lease.modelID,
            requestDigest: requestDigest,
            leaseTTLMilliseconds: lease.remainingTTLMilliseconds(),
            promptTokens: UInt64(clamping: lease.promptTokens),
            maxOutputTokens: UInt64(clamping: lease.maxOutputTokens),
            engineQueueDepth: UInt32(clamping: lease.engineQueueDepth),
            reservedKVBytes: lease.reservedKVBytes,
            reservedMediaBytes: lease.reservedMediaBytes,
            prefillCanBegin: lease.prefillCanBegin,
            estimatedPrefillMilliseconds: lease.estimatedPrefillMilliseconds
        )
    }

    private func prepareProtocolV2Inference(
        _ message: V2Prepare
    ) async throws -> PreparedInference {
        guard !isShuttingDown else { throw CancellationError() }
        guard !isDrainingForUpdate else {
            throw ProtocolV2PrepareError.draining
        }
        guard
            try V2Prepare.digest(of: message.encryptedBody)
                == message.requestDigest
        else {
            throw PreparedLeaseError.conflictingDuplicate
        }

        let plaintext = try keyPair.decryptPayload(message.encryptedBody)
        let openAIRequest = try Self.decodeOpenAIRequest(plaintext)
        guard openAIRequest.model == message.model else {
            throw PreparedInferenceError.modelMismatch(
                expected: message.model, actual: openAIRequest.model)
        }
        let responsePublicKey = try protocolV2ResponsePublicKey(
            message.encryptedBody)
        let reasoningEffort = Self.extractReasoningEffort(from: plaintext)
        let cacheScope = Self.extractCacheScope(from: plaintext)
        let logprobsSpec = Self.extractLogprobsSpec(from: plaintext)
        let sampling = Self.extractSamplingOverrides(from: plaintext)
        let pinID = message.identity.requestID.description

        guard requestToModel[pinID] == nil else {
            throw PreparedInferenceAdmissionError.duplicateRequestID
        }
        requestToModel[pinID] = message.model
        powerAssertion.acquire()
        syncWarmModelState()
        let release = PreparedInferenceResourceRelease { [weak self] in
            await self?.releaseProtocolV2ModelPin(
                requestID: pinID, modelID: message.model)
        }

        do {
            do {
                try await ensureModelLoaded(modelId: message.model)
            } catch {
                switch Self.loadErrorStatusCode(for: error) {
                case 429, 503:
                    throw ProtocolV2PrepareError.capacity
                default:
                    throw ProtocolV2PrepareError.modelNotReady
                }
            }
            guard requestToModel[pinID] == message.model,
                let slot = modelSlots[message.model]
            else {
                throw CancellationError()
            }
            modelSlots[message.model]?.lastInferenceAt = .now
            syncWarmModelState()

            var streamRequest = openAIRequest
            streamRequest.stream = true
            var streamOptions = streamRequest.streamOptions ?? OpenAIStreamOptions()
            streamOptions.includeUsage = true
            streamRequest.streamOptions = streamOptions
            if streamRequest.reasoningParser == nil {
                streamRequest.reasoningParser = Self.inferReasoningParser(
                    for: slot.modelType)
            }

            let logprobsChannel =
                logprobsSpec == nil
                ? nil : EngineV2LogprobsChannel()
            let usageSignal = EngineV2RequestUsageSignal()
            let internalRequest = MultiModelBatchSchedulerEngine.translate(
                openAIRequest: openAIRequest,
                defaultMaxTokens: Self.schedulerDefaultMaxTokens,
                logprobs: logprobsSpec == nil ? nil : true,
                topLogprobs: logprobsSpec?.topLogprobs,
                logitBias: sampling?.logitBias,
                seed: sampling?.seed
            )
            let maxOutputTokens =
                internalRequest.max_tokens
                ?? Self.schedulerDefaultMaxTokens

            let promptTokens: [Int]
            let multimodal: CBv2MultimodalInput?
            let mediaKind: EngineV2MediaKind?
            let mediaBytes: UInt64
            var toolCallFormat: ToolCallFormat?
            let toolSpecs = openAIRequest.tools?.map { $0.toolSpec() }

            if MediaIngest.hasMedia(openAIRequest) {
                guard slot.isVLM else {
                    throw
                        MultiModelBatchSchedulerEngineError
                        .mediaUnsupportedByModel(message.model)
                }
                try await MediaIngest.validateMedia(openAIRequest)
                let media = try await EngineV2VisionPrefill.prepare(
                    container: slot.container,
                    request: openAIRequest
                )
                promptTokens = media.promptTokens
                multimodal = media.multimodalInput()
                mediaKind = media.mediaKind
                let measured = media.embeddings.reduce(UInt64(0)) {
                    $0 &+ UInt64(max(0, $1.nbytes))
                }
                mediaBytes = max(1, measured)
            } else {
                let messages = openAIRequest.messages.map {
                    $0.templateMessageDict()
                }
                let context = reasoningEffort.map {
                    ["reasoning_effort": $0] as [String: any Sendable]
                }
                let fixContext = ChatTemplateFixContext(
                    modelId: message.model, modelType: slot.modelType)
                promptTokens = try slot.tokenizer.inner.applyChatTemplate(
                    messages: ChatTemplateFixes.normalizeMessages(
                        messages, context: fixContext),
                    tools: ChatTemplateFixes.normalizeTools(
                        toolSpecs, context: fixContext),
                    additionalContext: context
                )
                multimodal = nil
                mediaKind = nil
                mediaBytes = 0
                if openAIRequest.tools?.isEmpty == false {
                    toolCallFormat = try ServerToolParser.resolve(
                        requested: openAIRequest.toolCallParser,
                        modelType: slot.modelType
                    )
                }
            }

            return try PreparedInference(
                identity: message.identity,
                requestDigest: message.requestDigest.bytes.base64EncodedString(),
                modelID: message.model,
                promptTokens: promptTokens,
                request: internalRequest,
                cacheScope: cacheScope,
                logprobsChannel: logprobsChannel,
                usageSignal: usageSignal,
                multimodal: multimodal,
                mediaKind: mediaKind,
                streamRequest: streamRequest,
                responsePublicKey: responsePublicKey,
                tokenizer: slot.tokenizer,
                toolCallFormat: toolCallFormat,
                toolSpecs: toolSpecs,
                facts: PreparedInferenceFacts(
                    decryptionComplete: true,
                    renderingComplete: true,
                    tokenizationComplete: true,
                    promptTokens: promptTokens.count,
                    maxOutputTokens: maxOutputTokens,
                    mediaBytes: mediaBytes
                ),
                resourceRelease: release
            )
        } catch {
            await release.fire()
            throw error
        }
    }

    private func protocolV2Executor(
        for inference: PreparedInference
    ) throws -> any PreparedInferenceExecutor {
        guard let slot = modelSlots[inference.modelID] else {
            throw PreparedInferenceAdmissionError.modelMismatch(
                expected: inference.modelID, actual: "unloaded")
        }
        return slot.engineV2
    }

    private func protocolV2ResponsePublicKey(
        _ payload: EncryptedPayload
    ) throws -> Data {
        guard let key = Data(base64Encoded: payload.ephemeralPublicKey),
            key.count == 32,
            key.base64EncodedString() == payload.ephemeralPublicKey
        else {
            throw V2PrepareValidationError.invalidEncryptedPayload
        }
        return key
    }

    private func releaseProtocolV2ModelPin(
        requestID: String,
        modelID: String
    ) async {
        guard requestToModel[requestID] == modelID else { return }
        requestToModel.removeValue(forKey: requestID)
        powerAssertion.release()
        modelSlots[modelID]?.lastInferenceAt = .now
        syncWarmModelState()
        await updateAggregateCapacity()
    }

    private func streamProtocolV2Inference(
        prepared: PreparedInference,
        execution: PreparedInferenceExecution,
        session: V2NegotiatedSession,
        attempts: V2PreparedAttemptCoordinator,
        coordinator: CoordinatorClient,
        send: SendHandle
    ) async {
        var rolling = RollingResponseSHA256()
        var sequence: UInt64 = 0
        var completionTokens: UInt64 = 0
        let maxOutputTokens = UInt64(clamping: prepared.facts.maxOutputTokens)
        var visibleFrameCount: UInt64 = 0
        var deliveredSemanticText = ""
        var decorator = V2PreparedSSEFrameDecorator(prepared: prepared)
        var outcome: ProviderTerminalOutcome = .completed
        var errorClass: ProviderTerminalErrorClass?

        do {
            guard let request = prepared.streamRequest,
                let recipientKey = prepared.responsePublicKey
            else {
                throw PreparedInferenceError.incompleteRendering
            }
            let adapter = V2PreparedStreamAdapter(
                prepared: prepared, execution: execution)
            let service = MLXOpenAIService(engine: adapter)
            let frames = try await service.streamChatCompletionFrames(
                request: request)

            for try await frame in frames {
                try Task.checkCancellation()
                var nextDecorator = decorator
                let decorated = nextDecorator.decorate(frame)
                var nextCompletion = completionTokens
                var nextVisibleFrameCount = visibleFrameCount
                var nextDeliveredSemanticText = deliveredSemanticText
                if let parsed = decorated.parsed {
                    let visible =
                        (parsed.contentDelta?.isEmpty == false)
                        || (parsed.reasoningDelta?.isEmpty == false)
                        || (parsed.toolCallsDelta?.isEmpty == false)
                    if visible {
                        if nextVisibleFrameCount < UInt64.max {
                            nextVisibleFrameCount += 1
                        }
                        nextCompletion = max(nextCompletion, nextVisibleFrameCount)
                    }
                    if let content = parsed.contentDelta {
                        nextDeliveredSemanticText += content
                    }
                    if let reasoning = parsed.reasoningDelta {
                        nextDeliveredSemanticText += reasoning
                    }
                    if let toolCalls = parsed.toolCallsDelta {
                        nextDeliveredSemanticText += Self.encodeToolCallsForHash(toolCalls)
                    }
                    if let usage = parsed.usage {
                        nextCompletion = max(
                            nextCompletion,
                            UInt64(clamping: usage.completionTokens)
                        )
                    }
                }
                nextCompletion = min(nextCompletion, maxOutputTokens)

                var nextRolling = rolling
                let bytes = Data(decorated.frame.utf8)
                let checkpoint = try nextRolling.append(
                    sequence: sequence,
                    cumulativeTokens: nextCompletion,
                    responseBytes: bytes
                )
                let isFinal =
                    Self.joinedDataPayload(decorated.frame)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]"
                let header = try V2BinaryFrameHeader(
                    kind: .responseChunk,
                    flags: isFinal ? .finalFrame : .empty,
                    minor: session.capabilities.protocolMinor,
                    providerID: prepared.identity.providerID,
                    providerProcessGeneration:
                        prepared.identity.providerProcessGeneration,
                    sessionEpoch: prepared.identity.sessionEpoch,
                    requestID: prepared.identity.requestID,
                    attemptID: prepared.identity.attemptID,
                    reservationID: prepared.identity.reservationID,
                    leaseID: prepared.identity.leaseID,
                    nonce: Self.protocolV2Nonce(),
                    rollingDigest: checkpoint.rollingDigest.bytes,
                    sequence: sequence,
                    cumulativeTokens: nextCompletion
                )
                let wire = try keyPair.sealProtocolV2Frame(
                    recipientPublicKey: recipientKey,
                    header: header,
                    plaintext: bytes
                )
                try await coordinator.sendProtocolV2BinaryFrame(wire)
                rolling = nextRolling
                completionTokens = nextCompletion
                visibleFrameCount = nextVisibleFrameCount
                deliveredSemanticText = nextDeliveredSemanticText
                decorator = nextDecorator
                guard sequence < UInt64.max else {
                    throw TerminalCanonicalError.sequenceNotIncreasing(
                        previous: sequence, next: sequence)
                }
                sequence += 1
            }
            // AsyncThrowingStream ends normally when its consumer task is
            // cancelled. Re-check here so cancellation before the first frame (or
            // while awaiting the next frame) cannot be frozen as a successful
            // completion.
            try Task.checkCancellation()
        } catch is CancellationError {
            outcome = .cancelled
            errorClass = .cancelled
        } catch V2PreparedStreamAdapterError.cancelled {
            outcome = .cancelled
            errorClass = .cancelled
        } catch {
            if await coordinator.protocolV2Session()?.identity != session.identity {
                outcome = .cancelled
                errorClass = .cancelled
            } else {
                outcome = .error
                errorClass = .fault
            }
        }
        switch outcome {
        case .completed:
            break
        case .cancelled, .error:
            // Transport/framing failures can happen while the engine is still
            // generating. Quiesce it through the bounded lease control before
            // freezing terminal usage.
            _ = try? await attempts.cancel(identity: prepared.identity)
        }
        let actualEngineUsage = await execution.settledUsage()

        let checkpoint = rolling.checkpoint
        var deliveredTokenFloor: UInt64 = 0
        if let tokenizer = prepared.tokenizer, !deliveredSemanticText.isEmpty {
            deliveredTokenFloor = UInt64(
                clamping: tokenizer.inner.encode(
                    text: deliveredSemanticText, addSpecialTokens: false
                ).count)
        }
        completionTokens = min(
            maxOutputTokens,
            max(
                max(completionTokens, checkpoint.cumulativeTokens),
                max(visibleFrameCount, deliveredTokenFloor)
            )
        )
        let finalGeneratedTokens: UInt64 =
            outcome == .completed
            ? completionTokens
            : min(
                maxOutputTokens,
                max(completionTokens, actualEngineUsage.finalGeneratedTokens)
            )
        var reasoningTokens: UInt64 = 0
        if let tokenizer = prepared.tokenizer, !decorator.reasoningText.isEmpty {
            reasoningTokens = min(
                completionTokens,
                UInt64(
                    clamping: tokenizer.inner.encode(
                        text: decorator.reasoningText, addSpecialTokens: false
                    ).count)
            )
        }

        let frozen: FrozenProviderTerminal
        do {
            frozen = try await attempts.persistTerminal(
                identity: prepared.identity,
                draft: ProviderTerminalDraft(
                    outcome: outcome,
                    errorClass: errorClass,
                    completionTokens: completionTokens,
                    reasoningTokens: reasoningTokens,
                    responseHash: checkpoint.responseHash,
                    finalGeneratedTokens: finalGeneratedTokens,
                    rollingDigest: checkpoint.rollingDigest
                )
            )
        } catch {
            logger.error(
                "Protocol-v2 terminal persistence failed; paid admission is closed until reopen")
            return
        }

        // The journal replacement is durable before either send path. A failed
        // write leaves the terminal retained for the maintenance/reconnect replay.
        do {
            if await coordinator.protocolV2Session()?.identity
                == prepared.identity.providerSessionIdentity
            {
                try await coordinator.sendProtocolV2ControlMessage(
                    .providerTerminal(frozen.protocolV2)
                )
            } else {
                try await sendPendingProtocolV2Terminals(
                    attempts: attempts,
                    coordinator: coordinator
                )
            }
        } catch {
            logger.warning(
                "Protocol-v2 terminal send failed; durable replay remains pending")
        }
    }

    private func sendPendingProtocolV2Terminals(
        attempts: V2PreparedAttemptCoordinator,
        coordinator: CoordinatorClient
    ) async throws {
        for replay in try await attempts.pendingHistoricalReplays() {
            try Task.checkCancellation()
            try await coordinator.sendProtocolV2HistoricalTerminal(replay)
        }
    }

    private static func protocolV2Nonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data(
            (0..<V2FrameCrypto.nonceLength).map { _ in
                UInt8.random(in: .min ... .max, using: &generator)
            })
    }

    private func sendProtocolV2Error(
        _ error: Error,
        identity: AttemptIdentity,
        send: SendHandle
    ) {
        let errorClass: V2StructuredErrorClass
        let message: String
        switch error {
        case is V2PrepareValidationError, is CryptoError:
            errorClass = .invalidRequest
            message = "invalid encrypted request"
        case ProtocolV2PrepareError.draining:
            errorClass = .draining
            message = "provider is draining"
        case ProtocolV2PrepareError.modelNotReady:
            errorClass = .modelNotReady
            message = "model is not ready"
        case ProtocolV2PrepareError.capacity:
            errorClass = .capacity
            message = "model capacity unavailable"
        case PreparedLeaseError.identityConflict,
            PreparedLeaseError.conflictingDuplicate,
            PreparedLeaseError.completed:
            errorClass = .security
            message = "attempt state conflict"
        case is PreparedInferenceError:
            errorClass = .invalidRequest
            message = "invalid prepared request"
        case AttemptTombstoneError.capacityFull(_, _),
            AttemptTombstoneError.requiresReopen,
            TerminalJournalError.capacityFull(_, _),
            TerminalJournalError.tombstoneCapacityFull(_, _),
            TerminalJournalError.requiresReopen,
            V2PreparedAttemptCoordinatorError.notInitialized,
            V2PreparedAttemptCoordinatorError.paidAdmissionStopped:
            errorClass = .capacity
            message = "paid admission unavailable"
        case is AttemptTombstoneError,
            is TerminalJournalError,
            is V2PreparedAttemptCoordinatorError:
            errorClass = .security
            message = "attempt state conflict"
        case is PreparedInferenceAdmissionError:
            errorClass = .capacity
            message = "prepared capacity unavailable"
        case is CancellationError, PreparedLeaseError.cancelled,
            PreparedLeaseError.aborted, PreparedLeaseError.expired:
            errorClass = .cancelled
            message = "attempt cancelled"
        default:
            errorClass = .fault
            message = "provider could not process attempt"
        }
        send.send(
            .structuredError(
                V2StructuredError(
                    identity: identity,
                    errorClass: errorClass,
                    message: message
                )))
    }
}
