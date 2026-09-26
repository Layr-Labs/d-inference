import ArgumentParser
import Foundation
import ProviderCore

private struct ReportUploadResponse: Decodable {
    let reportID: Int64

    enum CodingKeys: String, CodingKey {
        case reportID = "report_id"
    }
}

private enum ReportLogAccess: Error { case denied }

private final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func set(_ value: String) { lock.withLock { text = value } }
    var value: String { lock.withLock { text } }
}

/// Explicit, operator-initiated support report.
///
/// Automatic log upload is intentionally not part of this command's lifecycle.
/// The collector scopes `log show` to Darkbloom's provider subsystem and does
/// not request private fields, so macOS unified-log redaction is preserved.
/// App Attest evidence (the daemon's closed local snapshot, APNs push history
/// and closed-pattern device-wide matches, not attributable to Darkbloom)
/// is appended to the same upload.
struct Report: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Upload recent provider unified logs for troubleshooting.",
        discussion: """
        Collects recent macOS unified logs for the dev.darkbloom.provider
        subsystem and uploads them to the coordinator only when you invoke this
        command. macOS privacy redactions are preserved. Use --dry-run to review
        the exact report locally before uploading it.

        Also appends App Attest evidence: the provider's last local App Attest
        snapshot, APNs push receipt/reply history, and device-wide devicecheckd /
        App Attest log observations from the last 2 hours reduced to a closed
        set of failure patterns and numeric codes. These observations may come
        from other apps and are not attributable to Darkbloom. macOS lets only
        administrator accounts read the system log: run this from an
        administrator account, or `sudo darkbloom report` if this account is
        allowed to use sudo.

        No other application or operating-system logs are included.
        """
    )

    @OptionGroup var configOptions: ConfigOptions

    @Option(name: .long, help: "Time window to collect (e.g. 1h, 6h, 24h).")
    var last: String = "24h"

    @Flag(name: .long, help: "Print the exact report instead of uploading it.")
    var dryRun = false

    static let subsystem = Logs.subsystem

    /// Pure argv builder kept separate from Process execution so scope and
    /// verbosity remain pinned by tests.
    static func logShowArguments(last: String) -> [String] {
        Array(
            Logs.showArgv(predicate: Logs.predicate, duration: last, debug: false)
                .dropFirst()
        )
    }

    static func decodeUploadReportID(_ data: Data) throws -> Int64 {
        try JSONDecoder().decode(ReportUploadResponse.self, from: data).reportID
    }

    mutating func run() async throws {
        let invokingHome = ReportAppAttestEvidence.adoptInvokingUserFiles()
        await runUpdateBannerIfEnabled()

        let snapshot: RuntimeSnapshot
        if invokingHome != nil {
            // Under sudo: the invoking user's config, and no on-disk
            // migration that would write it (or root's home) as root.
            Darkbloom.ensureLogging()
            snapshot = try loadRuntimeSnapshot(
                configPath: ReportAppAttestEvidence.configPath(explicit: configOptions.config, invokingHome: invokingHome),
                migrateOnDisk: false)
        } else {
            snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
        }
        let httpBase = coordinatorHTTPBase(snapshot.config.coordinator.url)

        print("Darkbloom Log Report")
        print("  Window:  \(last)")
        print("  Scope:   \(Self.subsystem) unified logs")
        print()

        print("Collecting unified logs...")
        var logData = Data()
        do {
            logData = try collectUnifiedLogs(last: last)
            if logData.isEmpty {
                print("  No provider logs for the given time window (is the provider running? Try: darkbloom start).")
            }
        } catch ReportLogAccess.denied {
            // Standard accounts cannot open the log store at all. Keep going:
            // the App Attest snapshot below is still worth sending.
            print("  Provider logs: not included — macOS denied log access (Operation not permitted).")
            print("  Fix: \(DeviceCheckEvidence.accessDeniedFix)")
        } catch {
            printError("Failed to collect logs: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        print("Collecting App Attest evidence...")
        var diagnosticData = ReportAppAttestEvidence.snapshotLine(
            state: DaemonStateFile.read(), pushHistory: APNsPushHistoryStore().load(), now: Date())
        let evidence = DeviceCheckEvidence.collect()
        diagnosticData.append(DeviceCheckEvidence.reportLines(evidence))
        let originalBytes = logData.count
        logData = try ReportPayload.assemble(logs: logData, evidence: diagnosticData)
        if logData.count < originalBytes + diagnosticData.count {
            print("  Provider logs trimmed to the newest complete lines to reserve room for diagnostics.")
        }
        switch evidence {
        case .collected(let events):
            print("  devicecheckd: \(DeviceCheckEvidence.summary(events))")
        case .accessDenied:
            print("  devicecheckd: not included — macOS denied log access (Operation not permitted).")
            print("  Fix: \(DeviceCheckEvidence.accessDeniedFix)")
        case .failed(let reason):
            print("  devicecheckd: not included — \(reason).")
        }

        let sizeMB = Double(logData.count) / 1_048_576.0
        print("  Collected \(logData.count) bytes (\(String(format: "%.1f", sizeMB)) MB)")

        if dryRun {
            print()
            guard let text = String(data: logData, encoding: .utf8) else {
                printError("Log data is not valid UTF-8")
                throw ExitCode.failure
            }
            print(text)
            return
        }

        guard logData.count <= ReportPayload.maxBytes else {
            printError("Log data exceeds 10 MB limit (\(String(format: "%.1f", sizeMB)) MB).")
            printError("Try a shorter time window: --last 6h or --last 1h")
            throw ExitCode.failure
        }

        print("Uploading to coordinator...")
        do {
            let reportID = try await uploadReport(
                httpBase: httpBase, logData: logData,
                token: ReportAppAttestEvidence.authToken(invokingHome: invokingHome))
            print()
            print("  Report uploaded successfully!")
            print("  Report ID: \(reportID)")
            print("  Share this report ID with the Darkbloom team for troubleshooting.")
        } catch {
            printError("Upload failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }

    private func collectUnifiedLogs(last: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = Self.logShowArguments(last: last)

        let pipe = Pipe()
        let errors = Pipe()
        process.standardOutput = pipe
        process.standardError = errors

        try process.run()
        // Drain stderr concurrently so a chatty failure cannot block stdout.
        let errorText = LockedText()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            errorText.set(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            drained.signal()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        drained.wait()

        if DeviceCheckEvidence.isAccessDenied(status: process.terminationStatus, stderr: errorText.value) {
            throw ReportLogAccess.denied
        }
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "darkbloom.report",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "log show exited with status \(process.terminationStatus)"]
            )
        }
        return data
    }

    private func uploadReport(httpBase: String, logData: Data, token: String?) async throws -> Int64 {
        guard let url = URL(string: "\(httpBase)/v1/provider/log-report") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        request.httpBody = logData
        request.timeoutInterval = 60

        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard httpResponse.statusCode == 201 else {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            throw NSError(
                domain: "darkbloom.report",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(body)"]
            )
        }
        return try Self.decodeUploadReportID(data)
    }

}
