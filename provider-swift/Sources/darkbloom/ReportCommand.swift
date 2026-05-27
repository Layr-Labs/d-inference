import ArgumentParser
import Foundation
import ProviderCore

struct Report: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Upload recent unified logs to the coordinator for troubleshooting.",
        discussion: """
        Collects the last 24 hours of macOS unified logs for the
        dev.darkbloom.provider subsystem and uploads them to the coordinator.
        The uploaded report can be retrieved by the Darkbloom team using
        your device's serial number.

        This command does NOT upload any logs from other apps or the
        operating system — only Darkbloom provider logs are included.
        """
    )

    @OptionGroup var configOptions: ConfigOptions

    @Option(name: .long, help: "Time window to collect (e.g. 1h, 6h, 24h).")
    var last: String = "24h"

    @Flag(name: .long, help: "Print the log content instead of uploading.")
    var dryRun = false

    mutating func run() async throws {
        await runUpdateBannerIfEnabled()

        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
        let coordinatorURL = snapshot.config.coordinator.url
        let httpBase = coordinatorHTTPBase(coordinatorURL)

        guard let serial = macHardwareSerialNumber(), !serial.isEmpty else {
            printError("Could not detect serial number. Run 'darkbloom doctor' for details.")
            throw ExitCode.failure
        }

        print("Darkbloom Log Report")
        print("  Serial:  \(serial)")
        print("  Window:  \(last)")
        print()

        // Collect unified logs
        print("Collecting unified logs...")
        let logData: Data
        do {
            logData = try collectUnifiedLogs(last: last)
        } catch {
            printError("Failed to collect logs: \(error)")
            throw ExitCode.failure
        }

        let sizeKB = Double(logData.count) / 1024.0
        let sizeMB = sizeKB / 1024.0
        print("  Collected \(logData.count) bytes (\(String(format: "%.1f", sizeMB)) MB)")

        if logData.isEmpty {
            print("  No logs found for the given time window.")
            print("  Is the provider running? Try: darkbloom start")
            return
        }

        if dryRun {
            print()
            if let text = String(data: logData, encoding: .utf8) {
                print(text)
            } else {
                printError("Log data is not valid UTF-8")
            }
            return
        }

        // Cap at 10 MB
        guard logData.count <= 10 * 1024 * 1024 else {
            printError("Log data exceeds 10 MB limit (\(String(format: "%.1f", sizeMB)) MB).")
            printError("Try a shorter time window: --last 6h or --last 1h")
            throw ExitCode.failure
        }

        // Upload to coordinator
        print("Uploading to coordinator...")
        do {
            let reportID = try await uploadReport(
                httpBase: httpBase,
                serial: serial,
                logData: logData
            )
            print()
            print("  Report uploaded successfully!")
            print("  Report ID: \(reportID)")
            print("  Serial:    \(serial)")
            print()
            print("  Share your serial number with the Darkbloom team so they")
            print("  can retrieve your logs for troubleshooting.")
        } catch {
            printError("Upload failed: \(error)")
            throw ExitCode.failure
        }
    }

    private func collectUnifiedLogs(last: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show",
            "--predicate", "subsystem == \"dev.darkbloom.provider\"",
            "--style", "ndjson",
            "--last", last,
            "--info",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return data
    }

    private func uploadReport(httpBase: String, serial: String, logData: Data) async throws -> Int64 {
        let urlString = "\(httpBase)/v1/provider/log-report?serial=\(serial)"
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = logData
        request.timeoutInterval = 60

        // Use saved auth token if available
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
                domain: "darkbloom",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(body)"]
            )
        }

        // Parse response for report ID
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = json["id"] as? Int64 {
            return id
        }
        // Fallback: return 0 if we can't parse the ID
        return 0
    }
}


