import Foundation
import Testing

@testable import darkbloom

@Suite("Explicit provider log report")
struct ReportCommandTests {
    @Test("report remains a registered user-invoked command")
    func commandIsRegistered() throws {
        let command = try Darkbloom.parseAsRoot([
            "report", "--last", "6h", "--dry-run",
        ])
        let report = try #require(command as? Report)

        #expect(report.last == "6h")
        #expect(report.dryRun)
    }

    @Test("collector is scoped to provider unified logs without debug output")
    func collectorScopeIsBounded() {
        let arguments = Report.logShowArguments(last: "24h")

        #expect(arguments == [
            "show",
            "--predicate", #"subsystem == "dev.darkbloom.provider""#,
            "--style", "ndjson",
            "--info",
            "--last", "24h",
        ])
        #expect(!arguments.contains("--debug"))
    }

    @Test("upload response returns a support ID without a serial")
    func uploadResponseUsesReportID() throws {
        let data = Data(#"{"status":"stored","report_id":42,"size_bytes":128}"#.utf8)
        #expect(try Report.decodeUploadReportID(data) == 42)
    }
}
