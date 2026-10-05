import ArgumentParser
import Foundation
import ProviderAppAttest
import ProviderCore
import Testing

@testable import darkbloom

/// `darkbloom report` end to end: the dry run prints the exact payload, and
/// the upload goes to the stub coordinator with the saved auth token. The
/// runs inject synthetic diagnostics and use a temporary provider home in a
/// child process (`CLICommandSandbox`), never reading host diagnostics.
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
            let state = DaemonState(
                pid: 42, version: "test", writtenAt: 150, startedAt: 10,
                appAttest: AppAttestLocalStatus(observedAt: 120, launchSession: .unknown))
            sandbox.writeState(state)
            let logs = Data(#"{"eventMessage":"synthetic provider log"}"#.utf8)
            let pushHistory = APNsPushHistory(deviceTokenPresent: true)
            let evidence = DeviceCheckEvidence.Outcome.collected([
                .init(timestamp: "2026-01-01T00:00:00Z", category: nil, messageType: nil,
                      matches: [.init(pattern: .cryptoTokenKitCode, code: -3)]),
            ])
            var diagnostics = ReportAppAttestEvidence.snapshotLine(
                state: state, pushHistory: pushHistory, now: Date(timeIntervalSince1970: 200))
            diagnostics.append(DeviceCheckEvidence.reportLines(evidence))
            let expectedPayload = try ReportPayload.assemble(logs: logs, evidence: diagnostics)

            func runReport(dryRun: Bool = false) async throws {
                var report = try #require(try Darkbloom.parseAsRoot(
                    ["report", "--config", sandbox.config.path, "--last", "1m"]
                        + (dryRun ? ["--dry-run"] : [])) as? Report)
                var calls: [String] = []
                defer { #expect(calls == ["logs", "pushHistory", "evidence"]) }
                try await report.run(
                    collectLogs: { last in
                        #expect(last == "1m")
                        calls.append("logs")
                        return logs
                    },
                    collectEvidence: {
                        calls.append("evidence")
                        return evidence
                    },
                    loadPushHistory: {
                        calls.append("pushHistory")
                        return pushHistory
                    })
            }

            print("== DRY RUN")
            try await runReport(dryRun: true)
            #expect(CoordinatorStub.requests.isEmpty)

            CoordinatorStub.install([
                "/v1/provider/log-report": .json(201, #"{"status":"stored","report_id":77,"size_bytes":10}"#),
            ])
            print("== UPLOAD")
            try await runReport()
            let upload = try #require(CoordinatorStub.requests.first)
            #expect(CoordinatorStub.requests.count == 1)
            #expect(upload.httpMethod == "POST")
            #expect(upload.url?.absoluteString == "https://coordinator.invalid/v1/provider/log-report")
            #expect(upload.value(forHTTPHeaderField: "Authorization") == "Bearer token-for-report")
            #expect(upload.value(forHTTPHeaderField: "Content-Type") == "application/x-ndjson")
            var body = upload.httpBody ?? Data()
            if let stream = upload.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    #expect(count >= 0)
                    guard count > 0 else { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            #expect(body == expectedPayload)

            CoordinatorStub.install(["/v1/provider/log-report": .json(503, "maintenance")])
            print("== REJECTED")
            do {
                try await runReport()
                Issue.record("Expected the rejected upload to fail")
            } catch {
                #expect((error as? ExitCode) == .failure)
            }
            print("== END")
        }
        let output = decodedText(result.standardOutputContent)
        let dryRun = try #require(outputSection(output, from: "== DRY RUN", to: "== UPLOAD"))
        #expect(dryRun.hasPrefix(
            "Darkbloom Log Report\n  Window:  1m\n  Scope:   dev.darkbloom.provider unified logs\n\n"
                + "Collecting unified logs...\n"))
        #expect(dryRun.contains("Collecting App Attest evidence...\n"))
        #expect(dryRun.contains("  devicecheckd: "))
        #expect(dryRun.contains("  Collected "))
        // The dry run prints the payload itself, including the closed
        // App Attest snapshot line, and never uploads.
        #expect(dryRun.contains(#""source":"darkbloom.app_attest_state""#))
        let payloadLines = dryRun.split(separator: "\n").filter { $0.hasPrefix("{") }
        #expect(payloadLines.count == 3)
        let payload = try payloadLines.map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(payload.first?["eventMessage"] as? String == "synthetic provider log")
        let snapshot = try #require(payload.first { $0["source"] as? String == "darkbloom.app_attest_state" })
        let appAttest = try #require(snapshot["app_attest"] as? [String: Any])
        #expect(appAttest["observed_at"] as? Int == 120)
        #expect(appAttest["launch_session"] as? String == "unknown")
        let pushHistory = try #require(snapshot["push_history"] as? [String: Any])
        #expect(pushHistory["device_token_present"] as? Bool == true)
        #expect(pushHistory["pushes_received_last_24h"] as? Int == 0)
        let evidence = try #require(payload.first { $0["source"] as? String == "darkbloom.devicecheck_evidence" })
        #expect(evidence["status"] as? String == "match")
        let event = try #require(evidence["event"] as? [String: Any])
        #expect(event["timestamp"] as? String == "2026-01-01T00:00:00Z")
        let matches = try #require(event["matches"] as? [[String: Any]])
        #expect(matches.count == 1)
        #expect(matches.first?["pattern"] as? String == "CryptoTokenKit Code")
        #expect(matches.first?["code"] as? Int == -3)
        #expect(!dryRun.contains("Uploading to coordinator..."))

        let upload = try #require(outputSection(output, from: "== UPLOAD", to: "== REJECTED"))
        #expect(upload.contains("Uploading to coordinator...\n"))
        #expect(upload.contains("  Report uploaded successfully!\n  Report ID: 77\n"))
        #expect(!upload.contains(#""source":"darkbloom.app_attest_state""#))

        let rejected = try #require(outputSection(output, from: "== REJECTED", to: "== END"))
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
}
