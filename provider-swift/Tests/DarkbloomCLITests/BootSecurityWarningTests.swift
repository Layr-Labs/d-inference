import ArgumentParser
import ProviderCore
import Testing
@testable import darkbloom

@Suite("start boot-security warnings")
struct BootSecurityWarningTests {
    private func render(
        _ snapshot: BootSecuritySnapshot,
        coordinatorEnforced: Bool
    ) throws -> String {
        let start = try Start.parse([])
        var lines: [String] = []
        start.warnBootSecurity(
            snapshot: snapshot,
            coordinatorEnforced: coordinatorEnforced,
            emit: { lines.append($0) }
        )
        return lines.joined(separator: "\n")
    }

    @Test("warnings are actionable and mode-specific")
    func warnings() throws {
        let snapshot = BootSecuritySnapshot(macOSMajorVersion: 25, sip: .disabled)
        let network = try render(snapshot, coordinatorEnforced: true)
        #expect(network.contains("WARNING"))
        #expect(network.contains("Software Update"))
        #expect(network.contains("csrutil enable"))
        #expect(network.contains("Coordinator trust policy"))

        let local = try render(snapshot, coordinatorEnforced: false)
        #expect(!local.contains("coordinator"))
        #expect(try render(.init(macOSMajorVersion: 26, sip: .enabled), coordinatorEnforced: true).isEmpty)
    }

    @Test("telemetry fields are categorical and allowlisted")
    func telemetry() throws {
        let start = try Start.parse([])
        let fields = start.bootSecurityTelemetryFields(
            .init(macOSMajorVersion: 25, sip: .disabled)
        )
        #expect(fields.count == 2)
        #expect(fields["boot_macos_major"]?.description == "25")
        #expect(fields["boot_sip_status"]?.description == "disabled")
        #expect(TelemetryFieldFilter.filter(fields)?.count == fields.count)
    }
}
