import Testing

@testable import darkbloom

@Suite("Retired provider log report command")
struct ReportCommandTests {
    @Test("report is no longer a registered command")
    func commandIsNotRegistered() {
        #expect(throws: (any Error).self) {
            _ = try Darkbloom.parseAsRoot(["report"])
        }
    }
}
