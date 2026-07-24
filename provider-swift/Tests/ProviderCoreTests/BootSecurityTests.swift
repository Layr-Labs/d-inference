import Testing
@testable import ProviderCore

@Suite("local boot-security posture")
struct BootSecurityTests {
    @Test("macOS and SIP map to compact warning issues")
    func issues() {
        let passing = BootSecuritySnapshot(macOSMajorVersion: 26, sip: .enabled)
        #expect(passing.issues.isEmpty)
        #expect(passing.macOSVerdict == .pass)
        #expect(passing.sipVerdict == .pass)

        let warning = BootSecuritySnapshot(
            macOSMajorVersion: 25,
            sip: .enabledWithCustomConfiguration(disabledProtections: ["Kext Signing"])
        )
        #expect(warning.issues.map(\.name) == ["macOS", "System Integrity Protection (SIP)"])
        #expect(warning.issues[0].fix.contains("Software Update"))
        #expect(warning.issues[1].fix.contains("csrutil enable"))
        #expect(warning.sip.summary.contains("Kext Signing"))
    }

    @Test("unavailable SIP remains warning-only and telemetry-safe")
    func unavailableSIP() {
        let snapshot = BootSecuritySnapshot(
            macOSMajorVersion: 26,
            sip: .unavailable(reason: "csrutil failed")
        )
        #expect(snapshot.sipVerdict == .warn)
        #expect(snapshot.sip.telemetryValue == "unavailable")
        #expect(snapshot.issues.first?.detail.contains("csrutil failed") == true)
        #expect(snapshot.issues.first?.fix.contains("darkbloom doctor") == true)
        #expect(snapshot.issues.first?.fix.contains("csrutil enable") == false)
    }

}
