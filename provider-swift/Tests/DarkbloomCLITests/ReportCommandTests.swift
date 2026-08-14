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
}
