import Foundation
import NIOCore
import MLXLMServer

extension DistributedLocalServer {
    nonisolated func makeApplication() -> LocalInferenceApplication {
        makeLocalInferenceApplication(config: config, defaultMaxTokens: defaultMaxTokens,
            acquire: { try await self.acquire($0) },
            tokenizerProvider: { try await self.resolveTokenizer($0) },
            availableModels: { await self.catalog() }, mtpSlots: { await self.metricsSamples() },
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
        guard acceptsPendingRequests else {
            throw MultiModelBatchSchedulerEngineError.requestRejected("Distributed session is unavailable")
        }
        if let response = DistributedHTTPResponseScope.current {
            guard responses.owns(response), !response.unavailableBeforeAdmission else {
                throw MultiModelBatchSchedulerEngineError.requestRejected("Distributed response is unavailable")
            }
        }
        let (target, id, queued) = try await waitForTurn()
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

    /// Pending requests belong to the listener and keep their original queue
    /// ceiling. Only the successful pin binds them to one native generation.
    private func waitForTurn() async throws -> (DistributedLocalServerGeneration, UUID, queued: Bool) {
        func take(_ target: DistributedLocalServerGeneration) throws -> UUID {
            try Task.checkCancellation()
            try DistributedHTTPResponseScope.current?.claimGeneration(target.id)
            let id = UUID(); target.pins.insert(id); return id
        }
        let initial = generation
        if waiting.isEmpty, await hasRoom(initial), waiting.isEmpty, servable(initial), initial.pins.count < initial.capacity {
            return (initial, try take(initial), false)
        }
        guard waiting.count < queue.maximumWaiting else {
            throw MultiModelBatchSchedulerEngineError.queueFull(DistributedRequestQueue.fullMessage)
        }
        let ticket = UUID()
        waiting.append(ticket)
        defer {
            waiting.removeAll { $0 == ticket }
            if waiting.isEmpty { replacementAttemptedDemand = 0; replacementRetryAt = nil }
        }
        let ceiling = ContinuousClock.now.advanced(by: queue.waitCeiling(
            requestTimeout: binding.requestTimeout, lanes: initial.capacity))
        considerBatchReplacement()
        while true {
            if Task.isCancelled || DistributedHTTPResponseScope.current?.unavailableBeforeAdmission == true {
                throw CancellationError()
            }
            guard acceptsPendingRequests else {
                throw MultiModelBatchSchedulerEngineError.requestRejected("Distributed session is unavailable")
            }
            // Check the original absolute ceiling before every admission,
            // including the first poll after a slow replacement load.
            guard ContinuousClock.now < ceiling else {
                throw MultiModelBatchSchedulerEngineError.requestRejected(DistributedRequestQueue.waitedTooLongMessage)
            }
            let target = generation
            if waiting.first == ticket, servable(target), await hasRoom(target),
               waiting.first == ticket, target.pins.count < target.capacity, servable(target) {
                return (target, try take(target), true)
            }
            considerBatchReplacement()
            try? await Task.sleep(for: DistributedRequestQueue.pollInterval)
        }
    }

    private var acceptsPendingRequests: Bool {
        teardownTask == nil && !failed && (phase == .reconfiguring || servable(generation))
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
        guard acceptsPendingRequests, let stableTokenizer else {
            throw MultiModelBatchSchedulerEngineError.requestRejected("Distributed session is unavailable")
        }
        return stableTokenizer
    }

    /// The pair's `/metrics` lines (`EngineV2Bridge.pairMetricsSample`): its
    /// MTP posture as the placed mode decodes (the session's speculation,
    /// `DistributedInstalledSpeculation`) and its counts, the requests it runs
    /// and the ones waiting for a lane.
    func metricsSamples() async -> [MTPSlotMetricsSample] {
        guard phase == .serving, let bridge = entry?.engineV2Bridge else { return [] }
        let waitingRequests = waiting.count
        let decodesWithHead = session.httpDiagnosticObservation?.mtpEnabled ?? false
        guard let sample = await bridge.pairMetricsSample(model: binding.publicModelID,
            waitingRequests: waitingRequests, placementDecodesWithHead: decodesWithHead) else { return [] }
        return [sample]
    }

    func catalog() -> [String] {
        acceptsPendingRequests ? [binding.publicModelID] : []
    }
}
