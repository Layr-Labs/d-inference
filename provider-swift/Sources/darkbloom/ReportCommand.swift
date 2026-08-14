import ArgumentParser
import Foundation
import ProviderCore

/// Explicit, operator-initiated support report.
///
/// Automatic log upload is intentionally not part of this command's lifecycle.
/// The collector scopes `log show` to Darkbloom's provider subsystem and does
/// not request private fields, so macOS unified-log redaction is preserved.
struct Report: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Upload recent provider unified logs for troubleshooting.",
        discussion: """
        Collects recent macOS unified logs for the dev.darkbloom.provider
        subsystem and uploads them to the coordinator only when you invoke this
        command. macOS privacy redactions are preserved. Use --dry-run to review
        the exact report locally before uploading it.

        Logs from other applications and operating-system subsystems are not
        included.
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

    mutating func run() async throws {
        await runUpdateBannerIfEnabled()

        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
        let httpBase = coordinatorHTTPBase(snapshot.config.coordinator.url)

        guard let serial = macHardwareSerialNumber(), !serial.isEmpty else {
            printError("Could not detect serial number. Run 'darkbloom doctor' for details.")
            throw ExitCode.failure
        }

        print("Darkbloom Log Report")
        print("  Serial:  \(serial)")
        print("  Window:  \(last)")
        print("  Scope:   \(Self.subsystem) unified logs")
        print()

        print("Collecting unified logs...")
        let logData: Data
        do {
            logData = try collectUnifiedLogs(last: last)
        } catch {
            printError("Failed to collect logs: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        let sizeMB = Double(logData.count) / 1_048_576.0
        print("  Collected \(logData.count) bytes (\(String(format: "%.1f", sizeMB)) MB)")

        guard !logData.isEmpty else {
            print("  No logs found for the given time window.")
            print("  Is the provider running? Try: darkbloom start")
            return
        }

        if dryRun {
            print()
            guard let text = String(data: logData, encoding: .utf8) else {
                printError("Log data is not valid UTF-8")
                throw ExitCode.failure
            }
            print(text)
            return
        }

        guard logData.count <= 10 * 1024 * 1024 else {
            printError("Log data exceeds 10 MB limit (\(String(format: "%.1f", sizeMB)) MB).")
            printError("Try a shorter time window: --last 6h or --last 1h")
            throw ExitCode.failure
        }

        print("Uploading to coordinator...")
        do {
            try await uploadReport(httpBase: httpBase, serial: serial, logData: logData)
            print()
            print("  Report uploaded successfully!")
            print("  Serial: \(serial)")
            print()
            print("  Share your serial number with the Darkbloom team so they")
            print("  can retrieve the report for troubleshooting.")
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
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "darkbloom.report",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "log show exited with status \(process.terminationStatus)"]
            )
        }
        return data
    }

    private func uploadReport(httpBase: String, serial: String, logData: Data) async throws {
        guard let url = URL(string: "\(httpBase)/v1/provider/log-report?serial=\(serial)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        request.httpBody = logData
        request.timeoutInterval = 60

        if let token = AuthTokenStore.load() {
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
    }

}
