import Foundation
import NIOCore
import MLXLMServer

extension DistributedLocalServer {
    nonisolated func makeApplication() -> LocalInferenceApplication {
        makeLocalInferenceApplication(config: config, defaultMaxTokens: defaultMaxTokens,
            acquire: { try await self.acquire($0) },
            tokenizerProvider: { try await self.resolveTokenizer($0) },
            availableModels: { await self.catalog() }, mtpSlots: { [] },
            onServerRunning: { await self.didBind($0) },
            modelTypeProvider: { [binding] in $0 == binding.publicModelID ? binding.modelType : nil },
            clusterStatus: { try await self.clusterStatus(nonce: $0) },
            distributedResponses: responseRouter)
    }

    func clusterStatus(nonce: String) throws -> ClusterLiveStatus {
        guard let observation = session.httpDiagnosticObservation, let port = boundPort else {
            throw ClusterConfigurationError.invalid("No installed cluster observation is available")
        }
        let ready = phase == .serving && !failed && observation.ready
        let admission = observation.admission
        return .init(schema: ClusterLiveStatus.schemaName, nonce: try ClusterStatusCodec.nonce(nonce),
            binding: observation.binding, authenticationConfigured: !(config.authToken ?? "").isEmpty,
            hostPhase: phase.rawValue, session: observation, boundPort: port,
            acquisitions: generation.pins.count, failed: failed, ready: ready,
            admissionAvailable: ready && generation.pins.count < generation.capacity && admission?.valid == true
                && admission?.activeRequest == false && admission?.draining == false,
            quarantined: phase == .quarantined || observation.phase == "quarantined")
    }

    func didBind(_ channel: any Channel) {
        guard phase == .starting,
              let port = channel.localAddress?.port, let port = UInt16(exactly: port), port != 0,
              session.status == .ready, session.readiness() != nil else {
            failed = true; beginTeardown(drainUntil: nil); return
        }
        let info = LocalEndpoint.Info(host: config.host, port: port, apiKey: config.authToken ?? "",
            version: ProviderCore.version, pid: ProcessInfo.processInfo.processIdentifier,
            updatedAt: ISO8601DateFormatter().string(from: Date()))
        do {
            try discovery?.publish(info)
            if discovery != nil { ownDiscovery = info }
            boundPort = port; phase = .serving
        } catch {
            failed = true; beginTeardown(drainUntil: nil)
        }
    }

    func acquire(_ modelID: String) async throws -> MultiModelBatchSchedulerEngine.AcquiredModel {
        guard modelID == binding.publicModelID else {
            throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelID)
        }
        // The pipeline takes as many acquisitions as the pair has lanes; further
        // requests wait in arrival order, in a bounded queue (`DistributedRequestQueue`).
        let target = generation
        guard servable(target) else {
            throw MultiModelBatchSchedulerEngineError.requestRejected("Distributed session is unavailable")
        }
        if let response = DistributedHTTPResponseScope.current {
            guard response.generationID == target.id, !response.isComplete else {
                throw MultiModelBatchSchedulerEngineError.requestRejected("Distributed response generation is unavailable")
            }
        }
        let (id, queued) = try await waitForTurn(target)
        guard let entry = target.entry else {
            release(id, generation: target)
            throw MultiModelBatchSchedulerEngineError.requestRejected("Distributed session is unavailable")
        }
        return .init(tokenizer: entry.tokenizer,
            releaseToken: OneShotRelease(release: { _ in await self.release(id, generation: target) }, modelId: modelID),
            modelType: entry.modelType, container: nil, isVLM: false,
            engineV2Bridge: entry.engineV2Bridge, visionGate: nil,
            queueExitedAt: queued ? ContinuousClock.now : nil)
    }

    /// The session serves and can take requests, now or after the queue.
    private func servable(_ target: DistributedLocalServerGeneration) -> Bool {
        phase == .serving && generation === target && target.entry != nil
            && target.session.status == .ready && !target.session.httpSessionInvalid
    }

    /// The pipeline has a free lane: fewer acquisitions than lanes, both ranks
    /// admit (the pair is busy only when every lane is taken), and the engine
    /// runs fewer requests than lanes (a retired one has left it).
    private func hasRoom(_ target: DistributedLocalServerGeneration) async -> Bool {
        guard target.pins.count < target.capacity, target.session.httpAdmissionAvailable,
              let bridge = target.entry?.engineV2Bridge else {
            return false
        }
        return await bridge.activeRequestCount() < target.capacity
    }

    /// Returns this request's acquisition once it is the oldest waiter and the
    /// pipeline is idle. The pin is taken here, with no suspension after the
    /// last check, so no later arrival can pass a waiter.
    private func waitForTurn(_ target: DistributedLocalServerGeneration) async throws -> (UUID, queued: Bool) {
        func take() -> UUID { let id = UUID(); target.pins.insert(id); return id }
        func free() -> Bool { target.pins.count < target.capacity }
        if waiting.isEmpty, await hasRoom(target), waiting.isEmpty, free(), servable(target) {
            return (take(), false)
        }
        guard waiting.count < queue.maximumWaiting else {
            throw MultiModelBatchSchedulerEngineError.queueFull(DistributedRequestQueue.fullMessage)
        }
        let ticket = UUID()
        waiting.append(ticket)
        defer { waiting.removeAll { $0 == ticket } }
        let ceiling = ContinuousClock.now.advanced(by: queue.waitCeiling(
            requestTimeout: target.session.profile.requestTimeout, lanes: target.capacity))
        while true {
            // A client that went away leaves the queue.
            if Task.isCancelled || DistributedHTTPResponseScope.current?.isComplete == true { throw CancellationError() }
            guard servable(target) else {
                throw MultiModelBatchSchedulerEngineError.requestRejected("Distributed session is unavailable")
            }
            if waiting.first == ticket, await hasRoom(target), waiting.first == ticket, free(), servable(target) {
                return (take(), true)
            }
            guard ContinuousClock.now < ceiling else {
                throw MultiModelBatchSchedulerEngineError.requestRejected(DistributedRequestQueue.waitedTooLongMessage)
            }
            try? await Task.sleep(for: DistributedRequestQueue.pollInterval)
        }
    }

    func release(_ id: UUID, generation target: DistributedLocalServerGeneration) {
        guard target.pins.remove(id) != nil, target.pins.isEmpty else { return }
        let waiters = target.pinWaiters; target.pinWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func resolveTokenizer(_ modelID: String?) throws -> MultiModelBatchSchedulerEngine.TokenizerResolution {
        if let modelID, modelID != binding.publicModelID {
            throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelID)
        }
        guard phase == .serving, session.status == .ready, let entry else {
            throw MultiModelBatchSchedulerEngineError.requestRejected("Distributed session is unavailable")
        }
        return .init(tokenizer: entry.tokenizer, modelType: entry.modelType)
    }

    func catalog() -> [String] {
        phase == .serving && session.status == .ready ? [session.model.publicModelID] : []
    }
}
