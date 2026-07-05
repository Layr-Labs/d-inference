/// ProviderLoop -- trust status + one-time auto-report.
///
/// Persists daemon state, reacts to coordinator `trust_status`, and uploads a
/// one-time unified-log auto-report when the provider learns it is untrusted.

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
    // MARK: - Trust Status & Auto-Report

    /// Handle a trust_status message from the coordinator. If the provider
    /// learns it is self_signed or untrusted, schedule a one-time auto-report
    /// of unified logs after 10 minutes.
    /// Assembles the current daemon state and writes it to the state file so the
    /// CLI (`status`/`doctor`) can read live state + the latest trust reason.
    /// Best-effort and cheap; safe to call from the trust handler and the
    /// periodic capacity loop.
    internal func writeDaemonState() {
        let cap = state.backendCapacity
        let snapshot = DaemonState(
            pid: getpid(),
            version: ProviderCore.version,
            writtenAt: Date().timeIntervalSince1970,
            startedAt: startedAtEpoch,
            trust: lastTrustStatus,
            currentModel: state.currentModel,
            warmModels: state.warmModels,
            inferenceActive: state.inferenceActive,
            stats: DaemonState.Stats(
                requestsServed: stats.requestsServed,
                tokensGenerated: stats.tokensGenerated,
                usageGaps: stats.usageGaps
            ),
            capacity: cap.map {
                DaemonState.Capacity(
                    totalMemoryGb: $0.totalMemoryGb,
                    gpuMemoryActiveGb: $0.gpuMemoryActiveGb,
                    gpuMemoryCacheGb: $0.gpuMemoryCacheGb)
            },
            lastModelLoadError: lastModelLoadError
        )
        DaemonStateFile.write(snapshot)
    }

    /// Records a model-load failure for the diagnostics state file so the
    /// operator sees the exact "Insufficient memory …" text in `doctor`.
    internal func recordModelLoadError(model: String, message: String) {
        lastModelLoadError = DaemonState.ModelLoadError(
            model: model, message: message, at: Date().timeIntervalSince1970)
        writeDaemonState()
    }

    internal func handleTrustStatus(trustLevel: String, status: String, reason: String) {
        logger.info("Trust status update: level=\(trustLevel) status=\(status) reason=\(reason)")

        // Cache + persist so `darkbloom status`/`doctor` can show the operator
        // the coordinator's reason (otherwise it is only in the logs).
        lastTrustStatus = DaemonState.Trust(
            trustLevel: trustLevel, status: status, reason: reason,
            receivedAt: Date().timeIntervalSince1970)
        writeDaemonState()

        let needsReport = trustLevel == "self_signed" || status == "untrusted"
        guard needsReport, !didAutoReport else {
            // Already reported or trust is fine — cancel any pending report.
            autoReportTask?.cancel()
            autoReportTask = nil
            return
        }

        // Schedule auto-report after 10 minutes. If the provider gets
        // upgraded to hardware trust before that, the task is cancelled.
        logger.warning("Provider is \(trustLevel)/\(status) — will auto-report logs in 10 minutes")
        autoReportTask?.cancel()
        autoReportTask = Task {
            do {
                try await Task.sleep(for: .seconds(600))
            } catch {
                return // cancelled (shutdown or trust upgraded)
            }
            guard !self.didAutoReport else { return }
            self.didAutoReport = true
            await self.submitAutoReport(trustLevel: trustLevel, status: status, reason: reason)
        }
    }

    /// Collect and upload unified logs to the coordinator.
    private func submitAutoReport(trustLevel: String, status: String, reason: String) async {
        logger.info("Auto-reporting unified logs (trust=\(trustLevel), status=\(status))")

        guard let serial = macHardwareSerialNumber(), !serial.isEmpty else {
            logger.warning("Auto-report skipped: serial number unavailable")
            return
        }

        // Collect last 24 hours of unified logs for our subsystem.
        let logData: Data
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = [
                "show",
                "--predicate", "subsystem == \"dev.darkbloom.provider\"",
                "--style", "ndjson",
                "--info",
                "--last", "24h",
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            logData = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        } catch {
            logger.error("Auto-report: failed to collect logs: \(error)")
            return
        }

        guard !logData.isEmpty else {
            logger.warning("Auto-report: no logs found")
            return
        }

        // Cap at 10 MB.
        let cappedData = logData.count > 10 * 1024 * 1024
            ? logData.prefix(10 * 1024 * 1024)
            : logData

        // Upload to coordinator.
        let httpBase = coordinatorHTTPBase(loopConfig.coordinatorURL)
        let urlString = "\(httpBase)/v1/provider/log-report?serial=\(serial)"
        guard let url = URL(string: urlString) else {
            logger.error("Auto-report: invalid URL: \(urlString)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(cappedData)
        request.timeoutInterval = 60

        if let token = AuthTokenStore.load() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResp = response as? HTTPURLResponse {
                if httpResp.statusCode == 201 {
                    let sizeMB = Double(cappedData.count) / 1_048_576.0
                    logger.info("Auto-report uploaded successfully (\(String(format: "%.1f", sizeMB)) MB)")
                } else {
                    logger.warning("Auto-report upload returned HTTP \(httpResp.statusCode)")
                }
            }
        } catch {
            logger.warning("Auto-report upload failed: \(error)")
        }
    }

}
