import ArgumentParser
import ProviderCore
import Testing

@testable import darkbloom

@Suite("status boot-security output")
struct StatusCommandTests {

    private func makeStatus() throws -> Status {
        try Status.parse([])
    }

    @Test("status reports warning SIP when SIP is unproven")
    func statusReportsSIPWarning() throws {
        let status = try makeStatus()
        let lines = status.bootSecurityStatusLines(
            BootSecuritySnapshot(sip: .unavailable(reason: "csrutil missing"), secureBoot: .fullSecurity)
        )
        let text = lines.joined(separator: "\n")
        #expect(text.contains("SIP: [WARN]"))
        #expect(text.contains("csrutil missing"))
    }

    @Test("status reports warning Secure Boot when Secure Boot is unproven")
    func statusReportsSecureBootWarning() throws {
        let status = try makeStatus()
        let lines = status.bootSecurityStatusLines(
            BootSecuritySnapshot(sip: .enabled, secureBoot: .unavailable(reason: "no controller"))
        )
        let text = lines.joined(separator: "\n")
        #expect(text.contains("Secure Boot: [WARN]"))
        #expect(text.contains("confirmed Secure Boot is required for hardware trust"))
    }

    @Test("status reports passing boot security when all boot protections pass")
    func statusReportsBootSecurityPass() throws {
        let status = try makeStatus()
        let lines = status.bootSecurityStatusLines(
            BootSecuritySnapshot(macOSMajorVersion: 26, sip: .enabled, secureBoot: .fullSecurity)
        )
        let text = lines.joined(separator: "\n")
        #expect(text.contains("macOS: [PASS]"))
        #expect(text.contains("SIP: [PASS]"))
        #expect(text.contains("Secure Boot: [PASS]"))
    }
}
