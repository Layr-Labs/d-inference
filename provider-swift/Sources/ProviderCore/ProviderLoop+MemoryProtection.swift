/// ProviderLoop -- OOM surfacing + live memory-pressure protection.
///
/// Consumes any prior-run OOM marker into telemetry and watches live memory
/// pressure (reclaim cache + drop a marker on critical for next-launch attribution).

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

extension ProviderLoop {
    // MARK: - Memory protection

    /// Surface any prior-run OOM (consume marker + scrape crash logs → oom
    /// telemetry) and watch live memory pressure (reclaim cache + drop a marker
    /// on critical so a kill before we can report it is attributed next launch).
    internal func startMemoryProtection() {
        // Pin the MLX memory ceiling BEFORE any model weights are loaded (the
        // first big allocation happens in ensureModelLoaded → loadModelContainer,
        // which runs after this). Idempotent; the BatchScheduler.loadModel call
        // is a backstop for the standalone path. See MLXMemoryGuard.
        MLXMemoryGuard.configureOnce(log: { [logger] limits in
            logger.info(
                "MLX memory ceiling: limit=\(limits.memoryLimitBytes / (1024 * 1024 * 1024))GB cache=\(limits.cacheLimitBytes / (1024 * 1024 * 1024))GB")
        })

        let now = Date()
        let since = OOMDetector.loadLastScan() ?? now.addingTimeInterval(-24 * 3600)
        let findings = OOMDetector.detectOnLaunch(since: since)
        for finding in findings {
            var fields: [String: AnyCodableValue] = ["detect_source": .string(finding.source.rawValue)]
            if let reason = finding.reason { fields["reason"] = .string(reason) }
            if let peak = finding.peakMemoryBytes { fields["peak_memory_bytes"] = .int64(Int64(clamping: peak)) }
            if let report = finding.reportName { fields["report"] = .string(report) }
            TelemetryClient.shared.emit(
                kind: .oom, severity: .error, message: finding.message, fields: fields)
            logger.error("OOM detected on launch: \(finding.message)")
        }
        // Advance the scan watermark only AFTER findings are handed to telemetry,
        // so a crash before this point re-scans the same reports next launch.
        OOMDetector.saveLastScan(now)

        let monitor = MemoryPressureMonitor(
            clearCache: { MLX.Memory.clearCache() },
            writeMarker: { _ in
                let marker = OOMDetector.Marker(
                    pid: ProcessInfo.processInfo.processIdentifier,
                    epochSeconds: Date().timeIntervalSince1970,
                    peakMemoryBytes: UInt64(max(0, MLX.Memory.peakMemory)),
                    availableBytesAtEvent: SystemMemory.availableBytes() ?? 0)
                OOMDetector.writeMarker(marker)
            },
            emit: { level, severity in
                TelemetryClient.shared.emit(
                    kind: .oom, severity: severity,
                    message: "memory pressure \(level.rawValue) — possible imminent OOM",
                    fields: [
                        "pressure": .string(level.rawValue),
                        "available_bytes": .int64(Int64(clamping: SystemMemory.availableBytes() ?? 0)),
                        "mlx_active_bytes": .int64(Int64(clamping: UInt64(max(0, MLX.Memory.activeMemory)))),
                    ])
            })
        monitor.start()
        self.memoryPressureMonitor = monitor
        logger.info("Memory protection active (OOM detection + pressure monitor)")
    }

}
