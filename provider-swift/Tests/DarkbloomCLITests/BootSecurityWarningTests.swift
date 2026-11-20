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

    @Test("a Darkbloom start inside a sandbox it didn't set up stops and says so; Only me only warns")
    func sandboxedRefusal() throws {
        let start = try Start.parse([])
        let sandboxed = BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled,
                                             sipConfiguration: SIPConfiguration(rawValue: 0), processSandbox: .sandboxed)
        var lines: [String] = []
        #expect(throws: ExitCode.self) {
            try start.refuseUnservableBootSecurity(snapshot: sandboxed, emit: { lines.append($0) })
        }
        let text = lines.joined(separator: "\n")
        // A sandbox says nothing about the Mac's boot settings.
        #expect(text.contains("Darkbloom serving stays off while Darkbloom can't verify this Mac's boot security."))
        #expect(!text.contains("until its boot security is at Apple's default"))
        #expect(text.contains("Process sandbox"))
        #expect(text.contains("standard installation"))

        // With another refusal, neither one alone explains it.
        let both = BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled,
                                        sipConfiguration: SIPConfiguration(rawValue: 0x24), processSandbox: .sandboxed)
        #expect(Start.servingOffBanner(both.servingRefusals)
                == "Darkbloom serving stays off on this Mac until the issues below are resolved.")

        let local = try render(sandboxed, coordinatorEnforced: false)
        #expect(!local.contains("Darkbloom serving stays off"))
        #expect(local.contains("WARNING: local boot security needs attention; continuing."))
        #expect(local.contains("Process sandbox"))
    }

    @Test("only a start that installs the Darkbloom service stops before its setup")
    func refusesBeforeSetup() {
        let refused = BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled,
                                           sipConfiguration: SIPConfiguration(rawValue: 0), processSandbox: .sandboxed)
        #expect(Start.refusesBeforeSetup(.service, bootSecurity: refused))
        // A service's child holds in the serve loop; Only me only warns.
        #expect(!Start.refusesBeforeSetup(.foreground, bootSecurity: refused))
        #expect(!Start.refusesBeforeSetup(.onlyMeHere, bootSecurity: refused))
        #expect(!Start.refusesBeforeSetup(.onlyMeService, bootSecurity: refused))
        let servable = BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled,
                                            sipConfiguration: SIPConfiguration(rawValue: 0), secureBoot: .full)
        #expect(!Start.refusesBeforeSetup(.service, bootSecurity: servable))
    }

    @Test("a paired --solo start goes on from the [local] settings it checked before touching the pair")
    func soloKeepsCheckedSettings() throws {
        let config = try TempConfig("[provider]\nname = \"solo\"\n\n[local]\nmode = \"network\"\n")
        defer { config.remove() }
        let environment = ServingEnvironment(accountKeySaved: { false }, ownLivePort: { nil }, installedPort: { nil },
                                             isFree: { _ in true })
        let start = try config.start(["--solo"])
        // Read and checked as Only me; the file says network by the time the start resolves: the checked choice holds.
        #expect(try start.resolveServing(environment: environment, saved: .some(LocalSettings(mode: .local))).mode == .local)
        // A checked Mac with no [local] section stays without one.
        #expect(try start.resolveServing(environment: environment, saved: .some(nil)).mode
                == start.resolveServing(environment: environment, saved: .some(LocalSettings())).mode)
        // Nothing checked: the file decides.
        #expect(try start.resolveServing(environment: environment).mode == .network)
    }

    @Test("a Darkbloom start with authenticated root off stops and names it; Only me only warns")
    func authenticatedRootRefusal() throws {
        let start = try Start.parse([])
        let off = BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled, sipConfiguration: SIPConfiguration(rawValue: 0),
                                       secureBoot: .full, authenticatedRoot: false)
        var lines: [String] = []
        #expect(throws: ExitCode.self) {
            try start.refuseUnservableBootSecurity(snapshot: off, emit: { lines.append($0) })
        }
        let text = lines.joined(separator: "\n")
        #expect(text.contains("Darkbloom serving stays off on this Mac until its boot security is at Apple's default."))
        #expect(text.contains("Authenticated root"))
        #expect(text.contains("csrutil authenticated-root enable"))
        let local = try render(off, coordinatorEnforced: false)
        #expect(local.contains("WARNING: local boot security needs attention; continuing."))
        #expect(local.contains("Authenticated root"))

        // Only a start that installs the Darkbloom service stops before its setup; an unread reading never does.
        #expect(Start.refusesBeforeSetup(.service, bootSecurity: off))
        for path: Start.SingleMacServing in [.foreground, .onlyMeHere, .onlyMeService] {
            #expect(!Start.refusesBeforeSetup(path, bootSecurity: off))
        }
        let unread = BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled, sipConfiguration: SIPConfiguration(rawValue: 0),
                                          secureBoot: .full, authenticatedRoot: nil)
        #expect(!Start.refusesBeforeSetup(.service, bootSecurity: unread))
    }

    @Test("telemetry fields are categorical")
    func telemetry() throws {
        let start = try Start.parse([])
        let fields = start.bootSecurityTelemetryFields(
            .init(macOSMajorVersion: 25, sip: .disabled)
        )
        #expect(fields.count == 3)
        #expect(fields["boot_macos_major"]?.description == "25")
        #expect(fields["boot_sip_status"]?.description == "disabled")
        #expect(fields["boot_process_sandbox"]?.description == "not_sandboxed")
        for (sandbox, value) in [(ProcessSandbox.sandboxed, "sandboxed"), (.unknown, "unknown")] {
            let reported = start.bootSecurityTelemetryFields(.init(macOSMajorVersion: 26, sip: .enabled,
                                                                   processSandbox: sandbox))
            #expect(reported["boot_process_sandbox"]?.description == value)
        }
    }
}
