import Foundation
import InferenceWorkerProtocol

private struct ProviderWorkerAuthenticatedMetadata: Codable, Sendable {
    let cacheReceiptNonce: String?
    let cacheScope: String?
    let prefixCacheProtocol: Int?
    let toolSchemaMetadataProtocol: Int?
}

extension ProviderLoop {
    internal var workerProcessPublicKeyBase64: String? {
        inferenceWorkerIdentity?.processPublicKey.base64EncodedString()
    }
    internal var isDrainingForUpdate: Bool { updateAdmissionClosed }


    internal func sendDrainingLoadModelFailure(modelId: String, send: SendHandle) {
        send.send(.loadModelStatus(
            modelId: modelId, status: .failed,
            error: providerDrainingForUpdateReason))
    }

    internal func sendDrainingPrefetchFailure(modelId: String, send: SendHandle) {
        send.send(.prefetchModelStatus(
            modelId: modelId, status: .failed, bytesDone: 0, bytesTotal: 0,
            error: providerDrainingForUpdateReason))
    }


    internal func initializeInferenceWorkerAfterHardening() async throws {
        guard securityHardeningCompleted,
              let binaryHash, binaryHash.count == 64 else {
            throw ProviderLoopError.inferenceWorkerBeforeHardening
        }
        LegacyInferenceKeyCleanup.removeRetiredFiles()
        await inferenceWorkerClient.setInvalidationHandler { [weak self] _ in
            Task { await self?.handleInferenceWorkerInvalidation() }
        }
        let identity = try await inferenceWorkerClient.connect()
        let broker = try ModelArtifactBroker()
        var workerModels: [ModelInfo] = []
        var descriptors: [WorkerModelArtifactDescriptor] = []
        for var model in advertisedModels.values.sorted(by: { $0.id < $1.id }) {
            guard let path = ModelScanner.resolveLocalPath(modelID: model.id),
                  let expectedHash = liveModelHashes[model.id] ?? modelHashes[model.id] ?? model.weightHash else {
                throw ProviderLoopError.inferenceWorkerConfigurationInvalid
            }
            model.weightHash = expectedHash
            descriptors.append(try broker.descriptor(
                modelIdentifier: model.id,
                snapshotURL: path,
                expectedManifestSHA256: expectedHash))
            workerModels.append(model)
        }
        let catalog = try JSONEncoder().encode(workerModels)
        let backend = loopConfig.config.backend
        let inferenceConfiguration = try JSONEncoder().encode(
            WorkerInferenceConfiguration(
                maximumCachedModels: Int(clamping: backend.maxModelSlots),
                engineV2MaximumConcurrent: backend.engineV2MaxConcurrent,
                engineV2MaximumConcurrentByModel:
                    backend.engineV2MaxConcurrentByModel,
                engineV2KVBackend: backend.engineV2KVBackend,
                engineV2KVBackendByModel: backend.engineV2KVBackendByModel,
                prefillDeadlineMode: backend.prefillDeadlineMode,
                mtpMode: backend.mtpMode))
        let releaseGeneration = updateLifecycle.record.command?.desiredGeneration
            ?? updateLifecycle.record.warmIntents.compactMap(\.desiredGeneration).max()
            ?? 0
        guard let configuration = WorkerBootstrapConfiguration(
            modelCatalogJSON: catalog,
            inferenceConfigurationJSON: inferenceConfiguration,
            artifacts: descriptors,
            releaseBinaryHash: binaryHash,
            releaseGeneration: releaseGeneration,
            modelGeneration: desiredModelGeneration,
            privateCacheLimitBytes: 20 * 1024 * 1024 * 1024,
            idleTimeoutMinutes:
                loopConfig.config.backend.idleTimeoutMins)
        else {
            throw ProviderLoopError.inferenceWorkerConfigurationInvalid
        }
        let result = try await inferenceWorkerClient.configure(configuration)
        guard result.runtimeCapabilitiesJSON
                == identity.runtimeCapabilitiesJSON,
              let capabilities = try? JSONDecoder().decode(
                [ProviderRuntimeCapability].self,
                from: result.runtimeCapabilitiesJSON)
        else {
            await inferenceWorkerClient.shutdown()
            throw ProviderLoopError.inferenceWorkerConfigurationInvalid
        }
        let accepted = Set(result.acceptedModelIdentifiers)
        advertisedModels = advertisedModels.filter {
            accepted.contains($0.key)
        }
        modelHashes = modelHashes.filter { accepted.contains($0.key) }
        liveModelHashes = liveModelHashes.filter {
            accepted.contains($0.key)
        }
        inferenceWorkerRuntimeCapabilities = Set(capabilities)
        if let coordinatorClient {
            await coordinatorClient.updateRuntimeCapabilities(
                inferenceWorkerRuntimeCapabilities)
        }
        inferenceWorkerIdentity = identity
    }

    @discardableResult
    internal func certifyInferenceWorkerForCurrentConnection() async -> Bool {
        guard let identity = inferenceWorkerIdentity else { return false }
        do {
            try await inferenceWorkerClient.markCertified(
                launchIdentifier: identity.launchIdentifier,
                connectionGeneration: coordinatorConnectionGeneration)
            return true
        } catch {
            return false
        }
    }

    internal func invalidateInferenceWorkerCertification() async {
        await inferenceWorkerClient.invalidateCertification()
    }
    internal func preloadWorkerModelTracked(_ modelIdentifier: String) async throws {
        guard !isShuttingDown, !isDrainingForUpdate else {
            throw InferenceWorkerClientError.notCertified
        }
        try await inferenceWorkerClient.preloadModel(identifier: modelIdentifier)
    }


    internal func forwardLegacyInferenceToWorker(
        requestId: String,
        ciphertext: Data,
        senderPublicKey: Data?,
        cacheReceiptNonce: String?,
        authenticatedCacheScope: String?,
        prefixCacheProtocol: Int?,
        toolSchemaMetadataProtocol: Int?,
        firstContentDeadline: FirstContentDeadline?,
        send: SendHandle
    ) async {
        guard let senderPublicKey else {
            send.send(.inferenceError(
                requestId: requestId,
                failure: InferenceFailure(code: .invalidRequest, statusCode: 400)))
            return
        }
        if let firstContentDeadline {
            do {
                try firstContentDeadline.check()
            } catch {
                send.send(.inferenceError(
                    requestId: requestId,
                    failure: InferenceFailure(code: .capacity, statusCode: 503)))
                return
            }
        }
        let deadlineUptimeNanoseconds: UInt64
        if let firstContentDeadline {
            let components = firstContentDeadline.remainingDuration().components
            let secondsNs = components.seconds.multipliedReportingOverflow(
                by: 1_000_000_000)
            let fractionalNs = components.attoseconds / 1_000_000_000
            let remainingNs = secondsNs.partialValue.addingReportingOverflow(
                fractionalNs)
            guard !secondsNs.overflow, !remainingNs.overflow,
                  remainingNs.partialValue > 0 else {
                send.send(.inferenceError(
                    requestId: requestId,
                    failure: InferenceFailure(code: .capacity, statusCode: 503)))
                return
            }
            let absolute = DispatchTime.now().uptimeNanoseconds
                .addingReportingOverflow(UInt64(remainingNs.partialValue))
            deadlineUptimeNanoseconds = absolute.overflow
                ? UInt64.max : absolute.partialValue
        } else {
            deadlineUptimeNanoseconds = 0
        }
        let metadata = ProviderWorkerAuthenticatedMetadata(
            cacheReceiptNonce: cacheReceiptNonce,
            cacheScope: authenticatedCacheScope,
            prefixCacheProtocol: prefixCacheProtocol,
            toolSchemaMetadataProtocol: toolSchemaMetadataProtocol)
        guard let request = WorkerInferenceRequest(
            kind: .legacy,
            requestIdentifier: requestId,
            envelope: ciphertext,
            senderPublicKey: senderPublicKey,
            authenticatedMetadataJSON: try? JSONEncoder().encode(metadata),
            firstContentDeadlineUptimeNanoseconds:
                deadlineUptimeNanoseconds) else {
            send.send(.inferenceError(
                requestId: requestId,
                failure: InferenceFailure(code: .invalidRequest, statusCode: 400)))
            return
        }
        await startWorkerForwarding(request: request, send: send)
    }

    internal func forwardPrivateV2InferenceToWorker(
        _ privateRequest: PrivateV2Request,
        send: SendHandle
    ) async {
        guard let encoded = try? JSONEncoder().encode(privateRequest),
              let request = WorkerInferenceRequest(
                kind: .privateV2,
                requestIdentifier: privateRequest.requestId,
                envelope: encoded,
                senderPublicKey: nil,
                authenticatedMetadataJSON: nil) else {
            send.send(.inferenceError(
                requestId: privateRequest.requestId,
                failure: InferenceFailure(
                    code: .invalidRequest, statusCode: 400)))
            return
        }
        await startWorkerForwarding(request: request, send: send)
    }

    private func startWorkerForwarding(
        request: WorkerInferenceRequest,
        send: SendHandle
    ) async {
        let requestID = request.requestIdentifier
        guard !isShuttingDown, !isDrainingForUpdate else {
            send.send(.inferenceError(
                requestId: requestID,
                failure: InferenceFailure(code: .capacity, statusCode: 503)))
            return
        }
        do {
            let stream = try await inferenceWorkerClient.submit(request)
            guard !isShuttingDown, !isDrainingForUpdate else {
                await inferenceWorkerClient.cancel(requestIdentifier: requestID)
                send.send(.inferenceError(
                    requestId: requestID,
                    failure: InferenceFailure(code: .capacity, statusCode: 503)))
                return
            }
            let providerStats = stats
            let task = Task { [weak self] in
                do {
                    for try await delivery in stream {
                        try await Self.forwardWorkerFrame(
                            delivery.frame,
                            send: send,
                            stats: providerStats)
                        await delivery.acknowledgeAfterForwarding()
                    }
                } catch {
                    send.send(.inferenceError(
                        requestId: requestID,
                        failure: InferenceFailure(code: .capacity, statusCode: 503)))
                    await self?.workerConnectionFailed()
                }
                await self?.workerForwardingFinished(requestID)
            }
            inflightTasks[requestID] = task
        } catch {
            send.send(.inferenceError(
                requestId: requestID,
                failure: InferenceFailure(code: .capacity, statusCode: 503)))
            await workerConnectionFailed()
        }
    }

    private func workerForwardingFinished(_ requestID: String) {
        inflightTasks.removeValue(forKey: requestID)
    }
    internal func workerConnectionFailed() async {
        startupPreloadGateCompleted = false
        guard !isShuttingDown else { return }
        inferenceWorkerIdentity = nil
        evidenceSentConnectionGeneration = nil
        certifiedConnectionGeneration = nil
        pendingCertifiedConnectionGeneration = nil
        do {
            // This always configures whichever authenticated process is current,
            // including a peer that reconnected before the idle callback ran.
            try await initializeInferenceWorkerAfterHardening()
            guard let identity = inferenceWorkerIdentity else {
                throw InferenceWorkerClientError.connectionFailed
            }
            if let coordinatorClient {
                let runtimeHashes = augmentRuntimeHashesWithMetallib(loopConfig.runtimeHashes)
                await coordinatorClient.refreshInferenceWorkerIdentity(
                    publicKey: identity.processPublicKey.base64EncodedString(),
                    registrationAttestation: makeRegistrationAttestationProvider(
                        runtimeHashes: runtimeHashes))
            }
        } catch {
            inferenceWorkerIdentity = nil
        }
    }

    private func handleInferenceWorkerInvalidation() async {
        await workerConnectionFailed()
    }


    private nonisolated static func forwardWorkerFrame(
        _ frame: WorkerResponseFrame,
        send: SendHandle,
        stats: AtomicProviderStats
    ) async throws {
        guard let kind = frame.kind else {
            throw InferenceWorkerClientError.invalidFrame
        }
        switch kind {
        case .accepted:
            send.send(.inferenceAccepted(requestId: frame.requestIdentifier))
        case .legacyEncryptedChunk:
            guard let publicKey = frame.ephemeralPublicKey else {
                throw InferenceWorkerClientError.invalidFrame
            }
            try await send.sendChunkAwaitingTransport(.inferenceChunk(
                requestId: frame.requestIdentifier,
                data: "",
                encryptedData: EncryptedPayload(
                    ephemeralPublicKey: publicKey.base64EncodedString(),
                    ciphertext: frame.payload.base64EncodedString())))
        case .privateV2EncryptedChunk:
            let chunk = try JSONDecoder().decode(
                PrivateV2Chunk.self, from: frame.payload)
            if chunk.terminal {
                send.send(.privateChunkV2(chunk))
            } else {
                try await send.sendChunkAwaitingTransport(.privateChunkV2(chunk))
            }
        case .terminal:
            let metadata = try frame.resultMetadataJSON.map {
                try JSONDecoder().decode(WorkerTerminalMetadata.self, from: $0)
            }
            if frame.failureCode == 0 {
                guard let responseHash = frame.responseHash else {
                    throw InferenceWorkerClientError.invalidFrame
                }
                if metadata?.prefixCacheProtocol == 2 {
                    if let lookupV2 = metadata?.lookupV2 {
                        send.send(.prefixCacheLookupV2(lookupV2.providerMessage))
                    }
                    if let readyV2 = metadata?.readyV2 {
                        send.send(.prefixCacheReadyV2(readyV2.providerMessage))
                    }
                }
                if let nonce = metadata?.cacheReceiptNonce,
                   metadata?.prefixCacheProtocol != 2 {
                    if let lookup = metadata?.lookup {
                        send.send(.prefixCacheLookup(
                            requestId: frame.requestIdentifier,
                            cacheReceiptNonce: nonce,
                            outcome: lookup.outcome,
                            tier: lookup.tier,
                            cachedTokens: lookup.cachedTokens > 0
                                ? lookup.cachedTokens : nil,
                            prefillTokensSaved: lookup.prefillTokensSaved > 0
                                ? lookup.prefillTokensSaved : nil,
                            stageMs: lookup.stageMilliseconds))
                    }
                    if let ready = metadata?.ready {
                        send.send(.prefixCacheReady(
                            requestId: frame.requestIdentifier,
                            cacheReceiptNonce: nonce,
                            readyTokens: ready.readyTokens,
                            requiredRecomputeTokens: ready.requiredRecomputeTokens,
                            expectedPrefillTokensSaved: ready.expectedPrefillTokensSaved,
                            tier: ready.tier,
                            stageMs: ready.stageMilliseconds))
                    }
                }
                stats.incrementRequestsServed()
                stats.addTokensGenerated(frame.completionTokens)
                if frame.promptTokens == 0 && frame.completionTokens == 0 {
                    stats.incrementUsageGaps()
                }
                send.send(.inferenceComplete(
                    requestId: frame.requestIdentifier,
                    usage: UsageInfo(
                        promptTokens: frame.promptTokens,
                        completionTokens: frame.completionTokens,
                        reasoningTokens: metadata?.reasoningTokens ?? 0,
                        cacheOutcome: metadata?.lookup?.outcome,
                        cacheTier: metadata?.lookup?.tier,
                        cachedTokens: metadata?.lookup?.cachedTokens,
                        prefillTokensSaved: metadata?.lookup?.prefillTokensSaved,
                        cacheStageMs: metadata?.lookup?.stageMilliseconds),
                    stopSequence: nil,
                    seSignature: frame.attestationSignature,
                    responseHash: responseHash))
            } else {
                let mapped: InferenceFailureCode
                switch InferenceWorkerErrorCode(rawValue: frame.failureCode) {
                case .invalidRequest, .requestTooLarge:
                    mapped = .invalidRequest
                case .cancelled:
                    mapped = .cancelled
                case .capacity, .backpressure, .notConfigured,
                     .connectionInvalidated, .invalidPeer:
                    mapped = .capacity
                default:
                    mapped = .generationFailure
                }
                send.send(.inferenceError(
                    requestId: frame.requestIdentifier,
                    failure: InferenceFailure(
                        code: mapped,
                        statusCode: frame.statusCode == 0 ? 500 : frame.statusCode,
                        errorReason: metadata?.errorReason,
                        terminalCause: metadata?.terminalCause,
                        attemptUsage: metadata?.attemptUsage)))
            }
        }
    }
}
