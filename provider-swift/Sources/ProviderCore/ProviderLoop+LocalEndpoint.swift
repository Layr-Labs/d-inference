/// ProviderLoop -- unified local OpenAI-compatible HTTP endpoint.
///
/// Serves a local endpoint alongside coordinator serving, backed by the SAME
/// loaded models (modelSlots) so weights load once and local + coordinator
/// requests share one continuous-batching engine and KV-cache budget.

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

// MARK: - Unified local endpoint

/// Serves a local OpenAI-compatible HTTP endpoint alongside coordinator serving,
/// backed by the SAME loaded models (`modelSlots`) so weights load once and
/// local + coordinator requests feed the same continuous-batching engine and the
/// same `GlobalKVCacheBudget` (so reported capacity reflects local load too).
///
/// Kept as a same-file extension so it can reach `ProviderLoop`'s private model
/// registry / load path without loosening their access for the whole module.
extension ProviderLoop {
    /// Start the local endpoint (idempotent). Runs the shared HTTP app in a
    /// child task; its registry closures reach back into this actor.
    func startLocalEndpoint(_ cfg: LocalInferenceHTTPConfig) {
        guard localServerTask == nil else { return }
        let app = makeLocalInferenceApplication(
            config: cfg,
            defaultMaxTokens: Self.schedulerDefaultMaxTokens,
            acquire: { [weak self] modelId in
                guard let self else { throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId) }
                return try await self.acquireModelForLocal(modelId)
            },
            tokenizerProvider: { [weak self] modelId in
                guard let self else { throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization }
                return try await self.resolveTokenizerForLocal(modelId)
            },
            availableModels: { [weak self] in
                guard let self else { return [] }
                return await self.advertisedLocalModelIds()
            },
            // Same per-server scope semantics as the standalone --local path
            // (PR #290 review): the local HTTP endpoint can't carry a
            // per-request prompt_cache_key, so honor the fixed
            // DARKBLOOM_PREFIX_CACHE_SCOPE here too. "" => unscoped. The
            // coordinator WS path is unaffected (it carries per-request scope).
            cacheScope: ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE_SCOPE"] ?? "",
            // Fires only once OUR server has actually bound the socket — the
            // authoritative bind signal. We publish discovery here (never from a
            // best-effort HTTP probe that a foreign process on the same port
            // could answer). If the bind fails, runService throws below and this
            // never runs, so no stale/foreign discovery record is written.
            onServerRunning: { [weak self] _ in
                await self?.onLocalEndpointBound(cfg)
            }
        )
        let log = logger
        localServerTask = Task {
            do {
                try await app.runService(gracefulShutdownSignals: [])
            } catch is CancellationError {
                // expected on shutdown
            } catch {
                // A bind failure (e.g. port already in use) lands here. We do NOT
                // kill the provider — coordinator serving must stay up — but make
                // the local-endpoint failure loud and operator-actionable.
                log.error("Local OpenAI endpoint did NOT bind on \(cfg.host):\(cfg.port) (port already in use?): \(error.localizedDescription). Coordinator serving is unaffected; restart with a free --port to enable the local endpoint.")
            }
        }
    }

    /// Invoked by Hummingbird once the local endpoint socket is bound and
    /// listening. Publishes the discovery record so `darkbloom local` /
    /// local-first clients find the unified endpoint — only now that the bind is
    /// CONFIRMED to be ours.
    private func onLocalEndpointBound(_ cfg: LocalInferenceHTTPConfig) {
        logger.info("Local OpenAI endpoint listening on \(cfg.host):\(cfg.port) (unified mode)")
        try? LocalEndpoint.writeInfo(LocalEndpoint.Info(
            host: cfg.host,
            port: cfg.port,
            apiKey: cfg.authToken ?? "",
            version: ProviderCore.version,
            pid: ProcessInfo.processInfo.processIdentifier,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        ))
    }

    /// Stop the local endpoint server, if running, and remove its discovery record.
    func stopLocalEndpoint() {
        guard localServerTask != nil else { return }
        localServerTask?.cancel()
        localServerTask = nil
        LocalEndpoint.removeInfo()
    }

    /// Acquire a resident model for a LOCAL request: ensure it's loaded, then
    /// hold a local reservation (released by the engine when the stream ends) so
    /// the idle monitor and load-gate eviction can't pull it mid-stream. Loading
    /// goes through the same `ensureModelLoaded` gate as coordinator requests, so
    /// the shared `GlobalKVCacheBudget` and memory admission apply uniformly.
    func acquireModelForLocal(_ modelId: String) async throws -> MultiModelBatchSchedulerEngine.AcquiredModel {
        // Fast-path drain/shutdown reject; an authoritative re-check follows the
        // `await` below, right before the reservation is taken (see comment there).
        try throwIfRefusingNewLocalWork()
        do {
            try await ensureModelLoaded(modelId: modelId)
        } catch let err as InferenceError {
            // Map load failures to the engine's typed errors (404 / 503).
            switch err {
            case .invalidModelDirectory, .noModelLoaded:
                throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
            default:
                throw MultiModelBatchSchedulerEngineError.queueFull("local capacity unavailable for \(modelId)")
            }
        }
        guard let slot = modelSlots[modelId] else {
            throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
        }
        // Authoritative re-check: `ensureModelLoaded` above is a suspension
        // point, so draining or shutdown may have begun while we were parked.
        // No `await` sits between this check and `reserve`, so on the actor it
        // is atomic — the reservation is either refused or counted in
        // `hasInflightWork` before any drain snapshot can miss it.
        try throwIfRefusingNewLocalWork()
        localReservations.reserve(modelId)
        modelSlots[modelId]?.lastInferenceAt = .now
        let release: @Sendable (String) async -> Void = { [weak self] mid in
            await self?.releaseLocalReservation(mid)
        }
        return MultiModelBatchSchedulerEngine.AcquiredModel(
            scheduler: slot.scheduler,
            tokenizer: slot.tokenizer,
            releaseToken: OneShotRelease(release: release, modelId: modelId),
            // From the loaded slot, not advertisedModels — correct during the
            // hard-swap drop window (see ModelSlot.modelType).
            modelType: slot.modelType,
            container: slot.container,
            isVLM: slot.isVLM
        )
    }

    /// Drop one local in-flight reservation for a model.
    func releaseLocalReservation(_ modelId: String) {
        localReservations.release(modelId)
        modelSlots[modelId]?.lastInferenceAt = .now
    }

    /// Whether a model currently has a local request in flight. Used by the idle
    /// monitor and eviction so they never unload a model a local stream is using.
    func hasLocalReservation(_ modelId: String) -> Bool {
        localReservations.isReserved(modelId)
    }

    /// Resolve a tokenizer for the local token-utility endpoints. Read-only, so
    /// (unlike `acquireModelForLocal`) it takes no reservation.
    func resolveTokenizerForLocal(_ modelId: String?) async throws -> TokenizerHandle {
        if let modelId {
            guard let slot = modelSlots[modelId] else {
                throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
            }
            return slot.tokenizer
        }
        if let firstKey = modelSlots.keys.sorted().first, let slot = modelSlots[firstKey] {
            return slot.tokenizer
        }
        throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization
    }

    /// The advertised `/v1/models` catalog for the local endpoint — everything
    /// this provider is configured to serve, not just the resident subset.
    func advertisedLocalModelIds() -> [String] {
        advertisedModels.keys.sorted()
    }
}
