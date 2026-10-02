import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// `darkbloom report` end to end: the dry run prints the exact payload, and
/// the upload goes to the stub coordinator with the saved auth token. The
/// runs read the real unified log (read-only, one minute window) and use a
/// temporary provider home in a child process (`CLICommandSandbox`).
@Suite("Report command run")
struct ReportCommandRunTests {

    @Test("dry run prints the payload; upload sends it with the token and prints the report ID")
    func dryRunAndUpload() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            try sandbox.writeToken("token-for-report")

            print("== DRY RUN")
            try await runCLICommand(
                Report.self, ["report", "--config", sandbox.config.path, "--last", "1m", "--dry-run"])
            #expect(CoordinatorStub.requests.isEmpty)

            CoordinatorStub.install([
                "/v1/provider/log-report": .json(201, #"{"status":"stored","report_id":77,"size_bytes":10}"#),
            ])
            print("== UPLOAD")
            try await runCLICommand(Report.self, ["report", "--config", sandbox.config.path, "--last", "1m"])
            let upload = try #require(CoordinatorStub.requests.first)
            #expect(CoordinatorStub.requests.count == 1)
            #expect(upload.httpMethod == "POST")
            #expect(upload.url?.absoluteString == "https://coordinator.invalid/v1/provider/log-report")
            #expect(upload.value(forHTTPHeaderField: "Authorization") == "Bearer token-for-report")
            #expect(upload.value(forHTTPHeaderField: "Content-Type") == "application/x-ndjson")

            CoordinatorStub.install(["/v1/provider/log-report": .json(503, "maintenance")])
            print("== REJECTED")
            let error = try await runFailingCLICommand(
                Report.self, ["report", "--config", sandbox.config.path, "--last", "1m"])
            #expect((error as? ExitCode) == .failure)
            print("== END")
        }
        let output = decodedText(result.standardOutputContent)
        let dryRun = try #require(Self.section(output, from: "== DRY RUN", to: "== UPLOAD"))
        #expect(dryRun.hasPrefix(
            "Darkbloom Log Report\n  Window:  1m\n  Scope:   dev.darkbloom.provider unified logs\n\n"
                + "Collecting unified logs...\n"))
        #expect(dryRun.contains("Collecting App Attest evidence...\n"))
        #expect(dryRun.contains("  devicecheckd: "))
        #expect(dryRun.contains("  Collected "))
        // The dry run prints the payload itself, including the closed
        // App Attest snapshot line, and never uploads.
        #expect(dryRun.contains(#""source":"darkbloom.app_attest_state""#))
        #expect(!dryRun.contains("Uploading to coordinator..."))

        let upload = try #require(Self.section(output, from: "== UPLOAD", to: "== REJECTED"))
        #expect(upload.contains("Uploading to coordinator...\n"))
        #expect(upload.contains("  Report uploaded successfully!\n  Report ID: 77\n"))
        #expect(!upload.contains(#""source":"darkbloom.app_attest_state""#))

        let rejected = try #require(Self.section(output, from: "== REJECTED", to: "== END"))
        #expect(rejected.contains("Uploading to coordinator...\n"))
        #expect(!rejected.contains("Report uploaded successfully!"))
    }

    @Test("report defaults to a 24 hour upload window")
    func defaults() throws {
        let report = try #require(try Darkbloom.parseAsRoot(["report"]) as? Report)
        #expect(report.last == "24h")
        #expect(!report.dryRun)
        #expect(Report.subsystem == "dev.darkbloom.provider")
    }

    @Test("an upload response without a report ID is rejected")
    func malformedUploadResponse() {
        #expect(throws: (any Error).self) {
            try Report.decodeUploadReportID(Data(#"{"status":"stored"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try Report.decodeUploadReportID(Data("not json".utf8))
        }
    }

    static func section(_ output: String, from start: String, to end: String) -> String? {
        guard let lower = output.range(of: start + "\n"),
              let upper = output.range(of: end, range: lower.upperBound..<output.endIndex)
        else { return nil }
        return String(output[lower.upperBound..<upper.lowerBound])
    }
}
