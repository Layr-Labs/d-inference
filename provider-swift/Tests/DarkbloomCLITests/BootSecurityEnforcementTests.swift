import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// Unit tests for the `start` boot-security warning wiring:
/// `enforceBootSecurity` emits actionable guidance without blocking serving, and
/// telemetry fields expose the posture for fleet rollout analysis. Boot state is
/// injected via `BootSecuritySnapshot`, so nothing here spawns `csrutil` /
/// `system_profiler` or depends on the host's boot policy.
@Suite("start boot-security enforcement")
struct BootSecurityEnforcementTests {

    /// Collects the lines `enforceBootSecurity` emits, in order.
    private final class Emitter {
        private(set) var lines: [String] = []
        func emit(_ line: String) { lines.append(line) }
        var text: String { lines.joined(separator: "\n") }
    }

    /// `Start` must be built through ArgumentParser's decoding lifecycle — its
    /// `@OptionGroup` property wrapper fatal-errors if constructed directly.
    private func makeStart(_ arguments: [String] = []) throws -> Start { try Start.parse(arguments) }

    @Test("SIP disabled warns and emits the enable guide without blocking")
    func warnsOnSIPDisabled() throws {
        let start = try makeStart()
        let emitter = Emitter()
        try start.enforceBootSecurity(
            snapshot: BootSecuritySnapshot(sip: .disabled, secureBoot: .fullSecurity),
            allowInsecureOverride: false,
            emit: emitter.emit
        )
        #expect(emitter.text.contains("WARNING"))
        #expect(emitter.text.contains("csrutil enable"))
        #expect(!emitter.text.contains("Refusing to start"))
    }

    @Test("Secure Boot downgrade warns without blocking")
    func warnsOnSecureBootDowngrade() throws {
        let start = try makeStart()
        let emitter = Emitter()
        try start.enforceBootSecurity(
            snapshot: BootSecuritySnapshot(sip: .enabled, secureBoot: .permissiveOrDisabled),
            allowInsecureOverride: false,
            emit: emitter.emit
        )
        #expect(emitter.text.contains("WARNING"))
        #expect(emitter.text.contains("Startup Security Utility"))
    }

    @Test("all protections fully on proceeds and emits nothing")
    func allOnDoesNotBlock() throws {
        let start = try makeStart()
        let emitter = Emitter()
        try start.enforceBootSecurity(
            snapshot: BootSecuritySnapshot(macOSMajorVersion: 26, sip: .enabled, secureBoot: .fullSecurity),
            allowInsecureOverride: false,
            emit: emitter.emit
        )
        #expect(emitter.lines.isEmpty)
    }

    @Test("macOS below the Tahoe floor warns with the upgrade guide")
    func warnsBelowMacOSFloor() throws {
        let start = try makeStart()
        let emitter = Emitter()
        try start.enforceBootSecurity(
            snapshot: BootSecuritySnapshot(macOSMajorVersion: 25, sip: .enabled, secureBoot: .fullSecurity),
            allowInsecureOverride: false,
            emit: emitter.emit
        )
        #expect(emitter.text.contains("WARNING"))
        #expect(emitter.text.contains("Software Update"))
        #expect(!emitter.text.contains("Refusing to start"))
    }

    @Test("escape hatch is accepted but unnecessary while boot-security rollout is non-blocking")
    func overrideIsNoOpWhileNonBlocking() throws {
        let start = try makeStart()
        let emitter = Emitter()
        try start.enforceBootSecurity(
            snapshot: BootSecuritySnapshot(macOSMajorVersion: 25, sip: .enabled, secureBoot: .fullSecurity),
            allowInsecureOverride: true,
            emit: emitter.emit
        )
        #expect(emitter.text.contains("WARNING"))
        #expect(!emitter.text.contains(BootSecurityPolicy.overrideEnvVar))
    }

    @Test("undeterminable Secure Boot warns without blocking")
    func unavailableSecureBootWarns() throws {
        let start = try makeStart()
        let emitter = Emitter()
        try start.enforceBootSecurity(
            snapshot: BootSecuritySnapshot(sip: .enabled, secureBoot: .unavailable(reason: "no controller")),
            allowInsecureOverride: false,
            emit: emitter.emit
        )
        #expect(emitter.text.contains("WARNING"))
        #expect(emitter.text.contains("confirmed Secure Boot"))
        #expect(!emitter.text.contains("Refusing to start"))
    }

    @Test("boot-security telemetry fields are categorical and filter-safe")
    func telemetryFields() throws {
        let start = try makeStart()
        let fields = start.bootSecurityTelemetryFields(
            BootSecuritySnapshot(macOSMajorVersion: 25, sip: .disabled, secureBoot: .reduced)
        )
        #expect(fields["boot_macos_major"]?.description == "25")
        #expect(fields["boot_macos_verdict"]?.description == "warn")
        #expect(fields["boot_sip_status"]?.description == "disabled")
        #expect(fields["boot_sip_verdict"]?.description == "warn")
        #expect(fields["boot_secure_boot_status"]?.description == "reduced")
        #expect(fields["boot_secure_boot_verdict"]?.description == "warn")
        #expect(start.bootSecurityTelemetrySeverity(BootSecuritySnapshot(
            macOSMajorVersion: 26,
            sip: .enabled,
            secureBoot: .fullSecurity
        )) == .info)
        #expect(start.bootSecurityTelemetrySeverity(BootSecuritySnapshot(
            macOSMajorVersion: 25,
            sip: .disabled,
            secureBoot: .reduced
        )) == .warn)
        #expect(TelemetryFieldFilter.filter(fields)?.count == fields.count)
    }

    @Test("allowInsecureBootOverride parses truthy / falsey / unset values")
    func overrideEnvParsing() {
        let key = BootSecurityPolicy.overrideEnvVar
        #expect(Start.allowInsecureBootOverride(environment: [key: "1"]))
        #expect(Start.allowInsecureBootOverride(environment: [key: " TRUE "]))
        #expect(Start.allowInsecureBootOverride(environment: [key: "yes"]))
        #expect(!Start.allowInsecureBootOverride(environment: [key: "0"]))
        #expect(!Start.allowInsecureBootOverride(environment: [key: "bogus"]))
        #expect(!Start.allowInsecureBootOverride(environment: [:]))
    }
}
