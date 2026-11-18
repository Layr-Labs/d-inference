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
        let olderMacOS = BootSecuritySnapshot(macOSMajorVersion: 25, sip: .enabled)
        let network = try render(olderMacOS, coordinatorEnforced: true)
        #expect(network.contains("WARNING: local boot security needs attention; continuing."))
        #expect(network.contains("Software Update"))
        #expect(network.contains("Coordinator trust policy"))

        // SIP not at its default refuses Darkbloom serving; the macOS warning follows it.
        let snapshot = BootSecuritySnapshot(macOSMajorVersion: 25, sip: .disabled)
        let refused = try render(snapshot, coordinatorEnforced: true)
        #expect(refused.contains("Darkbloom serving stays off on this Mac"))
        #expect(refused.contains("csrutil enable"))
        #expect(refused.contains("WARNING: local boot security also needs attention."))
        #expect(refused.contains("Software Update"))
        #expect(!refused.contains("continuing"))

        let local = try render(snapshot, coordinatorEnforced: false)
        #expect(!local.contains("coordinator"))
        #expect(local.contains("WARNING: local boot security needs attention; continuing."))
        #expect(local.contains("csrutil enable"))
        #expect(try render(.init(macOSMajorVersion: 26, sip: .enabled), coordinatorEnforced: true).isEmpty)
    }

    @Test("a Darkbloom start names each refusal and stops; Only me only warns")
    func refusal() throws {
        let start = try Start.parse([])
        let refused = BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled,
                                           sipConfiguration: SIPConfiguration(rawValue: 0x24), secureBoot: .permissive)
        var lines: [String] = []
        #expect(throws: ExitCode.self) {
            try start.refuseUnservableBootSecurity(snapshot: refused, emit: { lines.append($0) })
        }
        let text = lines.joined(separator: "\n")
        #expect(text.contains("Darkbloom serving stays off on this Mac"))
        #expect(text.contains("(0x24); off: Debugging Restrictions, DTrace Restrictions"))
        #expect(text.contains("csrutil enable"))
        #expect(text.contains("Full Security"))
        #expect(text.contains("start --local"))
        #expect(!text.contains("continuing"))

        let local = try render(refused, coordinatorEnforced: false)
        #expect(!local.contains("Darkbloom serving stays off"))
        #expect(local.contains("WARNING: local boot security needs attention; continuing."))
        #expect(local.contains("Debugging Restrictions, DTrace Restrictions"))

        var servable: [String] = []
        try start.refuseUnservableBootSecurity(
            snapshot: .init(macOSMajorVersion: 27, sip: .enabled, sipConfiguration: SIPConfiguration(rawValue: 0),
                            secureBoot: .full),
            emit: { servable.append($0) })
        #expect(servable.isEmpty)
    }

    @Test("telemetry fields are categorical")
    func telemetry() throws {
        let start = try Start.parse([])
        let fields = start.bootSecurityTelemetryFields(
            .init(macOSMajorVersion: 25, sip: .disabled)
        )
        #expect(fields.count == 2)
        #expect(fields["boot_macos_major"]?.description == "25")
        #expect(fields["boot_sip_status"]?.description == "disabled")
    }
}
