import ArgumentParser
import ProviderCore
import Testing
@testable import darkbloom

@Test("status compresses local posture and names MDM as Secure Boot authority")
func bootSecurityStatusLine() throws {
    let status = try Status.parse([])
    let warning = status.bootSecurityStatusLine(
        .init(macOSMajorVersion: 25, sip: .unavailable(reason: "csrutil missing"))
    )
    #expect(warning.contains("[WARN]"))
    #expect(warning.contains("csrutil missing"))
    #expect(warning.contains("Secure Boot is checked separately by coordinator MDM"))

    let passing = status.bootSecurityStatusLine(.init(macOSMajorVersion: 26, sip: .enabled))
    #expect(passing.contains("[PASS]"))
}
