// CoordinatorClient registration + heartbeat: send the registration frame and build
// the periodic heartbeat JSON (capacity, warm models, system metrics).

import Foundation
import Network
#if canImport(os)
import os
#endif

extension CoordinatorClient {
    // MARK: - Registration

    internal func sendRegistration(connection: NWConnection) async throws {
        let privacyCapabilities = config.privacyCapabilities ?? PrivacyCapabilities(
            textBackendInprocess: true,
            textProxyDisabled: true,
            pythonRuntimeLocked: true,
            dangerousModulesBlocked: true,
            sipEnabled: SecurityChecks.isSIPEnabled(),
            antiDebugEnabled: true,
            coreDumpsDisabled: true,
            envScrubbed: true
        )
        // Read the live advertised list (startup ∪ prefetched builds) rather
        // than the immutable `config.models`, so a re-registration after a
        // verified prefetch carries the updated set.
        let prefixCache = state.prefixCacheV2Advertisement()
        let jsonData = try CoordinatorClientCodec.encodeRegistration(
            from: config,
            models: advertisedModelStore.models,
            privacyCapabilities: privacyCapabilities,
            apnsDeviceTokenOverride: apnsTokenOverride,
            modelWeightHashOverrides: modelWeightHashOverrides,
            prefixCacheProtocol: prefixCache.protocolVersion,
            prefixCacheV2Models: prefixCache.protocolVersion == 2
                ? prefixCache.models : nil,
            prefixCacheStatuses: prefixCache.statuses,
            prefixCacheDonationOutcomes: prefixCache.donationOutcomes
        )
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw CoordinatorError.encodingFailed
        }
        // Registration is a BLOCKING send: the reconnect loop must not proceed to
        // the session tasks until the register frame is actually handed to the
        // transport (and any immediate write error surfaces here, triggering
        // backoff). Wrap the completion in a continuation to await it — unlike the
        // fire-and-forget hot path, this is once per connection, not per chunk.
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "register", metadata: [metadata])
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(jsonString.utf8),
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        cont.resume(throwing: CoordinatorError.connectionClosed(error))
                    } else {
                        cont.resume()
                    }
                }
            )
        }
    }

    // MARK: - Heartbeat

    func buildHeartbeatJSON() -> String {
        let isActive = state.inferenceActive
        let activeModel = state.currentModel
        let warmModels = state.warmModels
        let capacity = state.backendCapacity
        let prefixCache = state.prefixCacheV2Advertisement()
        let metrics = SystemMetricsCollector.collect(cpuCores: config.hardware.cpuCores.total)

        // Carry the APNs device token in every heartbeat (W5 Fix 2) so the
        // coordinator can re-arm a code-identity challenge WITHOUT a reconnect when
        // the token arrived after registration or rotated. Prefer the LIVE token
        // from the APNs bridge: on a post-registration rotation the bridge is
        // updated immediately, but `apnsTokenOverride`/`config` still hold the
        // value captured at startup, so reading them would keep pushing challenges
        // to the dead token until a reconnect. Fall back to the late-arrival
        // override, then the startup config value, when the bridge has none
        // (headless / no-GUI boxes never get a bridge token). nil when there is no
        // token at all, so token-less providers keep the wire shape unchanged
        // (encodeIfPresent omits the fields).
        let liveToken = liveAPNsToken()
        let effectiveToken = liveToken ?? apnsTokenOverride ?? config.apnsDeviceToken
        // Env mirrors the registration path: a dynamically-sourced token (live
        // bridge or late override) defaults to "production" when config carried no
        // environment; a config-only token keeps config's environment as-is.
        let effectiveEnv: String? = (liveToken != nil || apnsTokenOverride != nil)
            ? (config.apnsEnvironment ?? "production")
            : config.apnsEnvironment

        let message = CoordinatorClientCodec.heartbeatMessage(
            status: isActive ? .serving : .idle,
            activeModel: activeModel,
            warmModels: warmModels,
            stats: stats.snapshot(),
            systemMetrics: metrics,
            backendCapacity: capacity,
            apnsDeviceToken: effectiveToken,
            apnsEnvironment: effectiveEnv,
            prefixCacheProtocol: prefixCache.protocolVersion,
            prefixCacheV2Models: prefixCache.protocolVersion == 2
                ? prefixCache.models : nil,
            prefixCacheStatuses: prefixCache.statuses,
            prefixCacheDonationOutcomes: prefixCache.donationOutcomes
        )

        do {
            let data = try ProviderProtocolCodec.encodeProviderMessage(message)
            guard let json = String(data: data, encoding: .utf8) else {
                throw CoordinatorError.encodingFailed
            }
            return json
        } catch {
            recordEncodeFailure("heartbeat", error)
            // Last resort: a valid idle heartbeat keeps the connection alive
            // rather than shipping malformed bytes the coordinator would drop.
            return "{\"type\":\"heartbeat\",\"status\":\"idle\",\"stats\":{\"requests_served\":0,\"tokens_generated\":0},\"system_metrics\":{\"memory_pressure\":0,\"cpu_usage\":0,\"thermal_state\":\"nominal\"}}"
        }
    }

}
