import Testing
@testable import ProviderCore

@Suite("local boot-security posture")
struct BootSecurityTests {
    @Test("a SIP custom configuration refuses serving; the macOS version stays a warning")
    func issues() {
        let passing = BootSecuritySnapshot(macOSMajorVersion: 26, sip: .enabled)
        #expect(passing.issues.isEmpty)
        #expect(passing.servingRefusals.isEmpty)
        #expect(passing.macOSVerdict == .pass)
        #expect(passing.sipVerdict == .pass)

        let refused = BootSecuritySnapshot(
            macOSMajorVersion: 25,
            sip: .enabledWithCustomConfiguration(disabledProtections: ["Kext Signing"])
        )
        #expect(refused.servingRefusals.map(\.name) == ["System Integrity Protection (SIP)"])
        #expect(refused.issues.map(\.name) == ["System Integrity Protection (SIP)", "macOS"])
        #expect(refused.sipVerdict == .fail)
        #expect(refused.issues[0].fix.contains("csrutil enable"))
        #expect(refused.issues[1].fix.contains("Software Update"))
        #expect(refused.sip.summary.contains("Kext Signing"))
    }

    @Test("an unreadable SIP status refuses serving and stays telemetry-safe")
    func unavailableSIP() {
        let snapshot = BootSecuritySnapshot(
            macOSMajorVersion: 26,
            sip: .unavailable(reason: "csrutil failed")
        )
        #expect(snapshot.sipVerdict == .fail)
        #expect(snapshot.sip.telemetryValue == "unavailable")
        #expect(snapshot.issues.first?.detail.contains("csrutil failed") == true)
        #expect(snapshot.issues.first?.fix.contains("darkbloom doctor") == true)
        #expect(snapshot.issues.first?.fix.contains("csrutil enable") == false)
    }

}
