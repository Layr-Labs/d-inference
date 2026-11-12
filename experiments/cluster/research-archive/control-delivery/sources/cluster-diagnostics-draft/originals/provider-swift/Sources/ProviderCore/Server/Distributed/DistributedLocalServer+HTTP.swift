import Foundation
import NIOCore

extension DistributedLocalServer {
    nonisolated func makeApplication() -> LocalInferenceApplication {
        makeLocalInferenceApplication(config: config, defaultMaxTokens: session.profile.maxOutputTokens,
            acquire: { try await self.acquire($0) },
            tokenizerProvider: { try await self.resolveTokenizer($0) },
            availableModels: { await self.catalog() }, mtpSlots: { [] },
            onServerRunning: { await self.didBind($0) })
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
        guard modelID == session.model.publicModelID else {
            throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelID)
        }
        // A single pipeline has one acquisition. No host-side waiting queue can
        // retain unlimited tokenizers/requests or extend owner lifetime.
        guard phase == .serving, pin == nil, let entry,
              session.httpAdmissionAvailable else {
            throw MultiModelBatchSchedulerEngineError.requestRejected("Distributed session is unavailable")
        }
        let id = UUID(); pin = id
        return .init(tokenizer: entry.tokenizer,
            releaseToken: OneShotRelease(release: { _ in await self.release(id) }, modelId: modelID),
            modelType: entry.modelType, container: nil, isVLM: false,
            engineV2Bridge: entry.engineV2Bridge, visionGate: nil)
    }

    private func release(_ id: UUID) {
        guard pin == id else { return }
        pin = nil
        let waiters = pinWaiters; pinWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func resolveTokenizer(_ modelID: String?) throws -> MultiModelBatchSchedulerEngine.TokenizerResolution {
        if let modelID, modelID != session.model.publicModelID {
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
