import Foundation
import NIOCore

extension DistributedLocalServer {
    nonisolated func makeApplication() -> LocalInferenceApplication {
        makeLocalInferenceApplication(config: config, defaultMaxTokens: defaultMaxTokens,
            acquire: { try await self.acquire($0) },
            tokenizerProvider: { try await self.resolveTokenizer($0) },
            availableModels: { await self.catalog() }, mtpSlots: { [] },
            clusterStatus: { try await self.clusterStatus(nonce: $0) },
            distributedResponses: responseRouter,
            onServerRunning: { await self.didBind($0) })
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
            acquisitions: pin == nil ? 0 : 1, failed: failed, ready: ready,
            admissionAvailable: ready && pin == nil && admission?.valid == true
                && admission?.activeRequest == false && admission?.draining == false
                && (admission?.remainingRequests ?? 0) > 0,
            quarantined: phase == .quarantined || observation.phase == "quarantined")
    }

    func didBind(_ channel: any Channel) {
        guard phase == .starting,
              let port = channel.localAddress?.port, let port = UInt16(exactly: port), port != 0,
              let deadline = session.lifetimeDeadlineUptimeNanoseconds,
              DispatchTime.now().uptimeNanoseconds < deadline,
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

    func acquire(_ modelID: String) throws -> MultiModelBatchSchedulerEngine.AcquiredModel {
        guard modelID == binding.publicModelID else {
            throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelID)
        }
        // A single pipeline has one acquisition. No host-side waiting queue can
        // retain unlimited tokenizers/requests or extend owner lifetime.
        let target = generation
        guard phase == .serving, target.pin == nil, let entry = target.entry,
              target.session.httpAdmissionAvailable else {
            throw MultiModelBatchSchedulerEngineError.requestRejected("Distributed session is unavailable")
        }
        if let response = DistributedHTTPResponseScope.current {
            guard response.generationID == target.id, !response.isComplete else {
                throw MultiModelBatchSchedulerEngineError.requestRejected("Distributed response generation is unavailable")
            }
        }
        let id = UUID(); target.pin = id
        return .init(tokenizer: entry.tokenizer,
            releaseToken: OneShotRelease(release: { _ in await self.release(id, generation: target) }, modelId: modelID),
            modelType: entry.modelType, container: nil, isVLM: false,
            engineV2Bridge: entry.engineV2Bridge, visionGate: nil)
    }

    private func release(_ id: UUID, generation target: DistributedLocalServerGeneration) {
        guard target.pin == id else { return }
        target.pin = nil
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
