import Foundation
import MLXLMCommon
#if canImport(os)
import os
#endif

extension EngineV2Bridge {
    #if canImport(os)
    private static let mtpLogger = Logger(
        subsystem: "com.darkbloom.provider", category: "engine_v2_mtp")
    #endif

    func configureMTPStatus(
        _ status: MTPActivationStatus,
        metricsInterval: Duration = .seconds(60)
    ) {
        mtpActivationStatus = status
        mtpMetricsTask?.cancel()
        mtpMetricsTask = nil
        guard status.active, metricsInterval > .zero else { return }
        let bridge = self
        mtpMetricsTask = Task { [weak bridge] in
            while !Task.isCancelled {
                try? await taskSleep(metricsInterval)
                if Task.isCancelled { return }
                guard let bridge else { return }
                await bridge.logMTPSnapshot()
            }
        }
    }

    /// Public/test-visible lock-safe snapshot. `EngineV2.mtpMetricsSnapshot()`
    /// takes the engine's metrics lock; this adapter never reaches controller
    /// mutation or the inference loop.
    public func mtpStatusSnapshot() -> ProviderMTPStatusSnapshot {
        let metrics = (ownedEngine as? EngineV2)?.mtpMetricsSnapshot()
        return ProviderMTPStatusSnapshot(status: mtpActivationStatus, metrics: metrics)
    }

    private func logMTPSnapshot() {
        let snapshot = mtpStatusSnapshot()
        #if canImport(os)
        let reason = snapshot.fallbackReason?.rawValue ?? "none"
        let revision = snapshot.assistantRevision ?? "none"
        let skipped = snapshot.skippedRows.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let controller = snapshot.controllerFallbacks.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        Self.mtpLogger.info(
            "mtp metrics model=\(self.modelId, privacy: .public) configured=\(snapshot.configured) active=\(snapshot.active) reason=\(reason, privacy: .public) revision=\(revision, privacy: .public) assistant_bytes=\(snapshot.assistantResidentBytes) depth=\(snapshot.selectedDepth) decode_bucket=\(snapshot.decodeRowBucket) rounds=\(snapshot.rounds) seeds=\(snapshot.seedRows) proposed=\(snapshot.proposedTokens) accepted=\(snapshot.acceptedDraftTokens) emitted=\(snapshot.committedEmittedTokens) skipped=\(skipped, privacy: .public) controller=\(controller, privacy: .public)"
        )
        #endif
    }
}
