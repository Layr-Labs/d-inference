import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// Unit tests for the `start` boot-security gate wiring: `enforceBootSecurity`
/// (block / warn / proceed + emitted guide) and the `allowInsecureBootOverride`
/// escape-hatch env parsing. Boot state is injected via `BootSecuritySnapshot`,
/// so nothing here spawns `csrutil` / `system_profiler` or depends on the host's
/// boot policy.
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
    private func makeStart() throws -> Start { try Start.parse([]) }

    @Test("confident failure throws ExitCode.failure and emits the enable guide")
    func blocksOnConfidentFailure() throws {
        let start = try makeStart()
        let emitter = Emitter()
        do {
            try start.enforceBootSecurity(
                snapshot: BootSecuritySnapshot(sip: .disabled, secureBoot: .fullSecurity),
                allowInsecureOverride: false,
                emit: emitter.emit
            )
            Issue.record("expected enforceBootSecurity to throw on a confident failure")
        } catch let code as ExitCode {
            #expect(code == .failure)
        }
        #expect(emitter.text.contains("csrutil enable"))
        #expect(emitter.text.contains("Refusing to start"))
    }

    @Test("Secure Boot downgrade (permissiveOrDisabled) blocks startup")
    func blocksOnSecureBootDowngrade() throws {
        let start = try makeStart()
        let emitter = Emitter()
        do {
            try start.enforceBootSecurity(
                snapshot: BootSecuritySnapshot(sip: .enabled, secureBoot: .permissiveOrDisabled),
                allowInsecureOverride: false,
                emit: emitter.emit
            )
            Issue.record("expected a block on a Secure Boot downgrade")
        } catch let code as ExitCode {
            #expect(code == .failure)
        }
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

    @Test("macOS below the Tahoe floor blocks startup with the upgrade guide")
    func blocksBelowMacOSFloor() throws {
        let start = try makeStart()
        let emitter = Emitter()
        do {
            try start.enforceBootSecurity(
                snapshot: BootSecuritySnapshot(macOSMajorVersion: 25, sip: .enabled, secureBoot: .fullSecurity),
                allowInsecureOverride: false,
                emit: emitter.emit
            )
            Issue.record("expected a block below the macOS 26 (Tahoe) floor")
        } catch let code as ExitCode {
            #expect(code == .failure)
        }
        #expect(emitter.text.contains("Software Update"))
        #expect(emitter.text.contains("Refusing to start"))
    }

    @Test("escape hatch downgrades a below-floor macOS failure to a warning (no throw)")
    func overrideAllowsStartBelowMacOSFloor() throws {
        let start = try makeStart()
        let emitter = Emitter()
        try start.enforceBootSecurity(
            snapshot: BootSecuritySnapshot(macOSMajorVersion: 25, sip: .enabled, secureBoot: .fullSecurity),
            allowInsecureOverride: true,
            emit: emitter.emit
        )
        #expect(emitter.text.contains(BootSecurityPolicy.overrideEnvVar))
        #expect(emitter.text.contains("DO NOT serve production"))
    }

    @Test("undeterminable Secure Boot warns but proceeds (no throw)")
    func warnDoesNotBlock() throws {
        let start = try makeStart()
        let emitter = Emitter()
        try start.enforceBootSecurity(
            snapshot: BootSecuritySnapshot(sip: .enabled, secureBoot: .unavailable(reason: "no controller")),
            allowInsecureOverride: false,
            emit: emitter.emit
        )
        #expect(emitter.text.contains("WARNING"))
        // The warn line must clarify that proceeding locally is NOT admission:
        // the coordinator still rejects until Secure Boot is confirmed.
        #expect(emitter.text.contains("coordinator"))
        #expect(emitter.text.contains("does not guarantee admission"))
    }

    @Test("escape hatch downgrades a hard failure to a loud warning (no throw)")
    func overrideAllowsStart() throws {
        let start = try makeStart()
        let emitter = Emitter()
        try start.enforceBootSecurity(
            snapshot: BootSecuritySnapshot(sip: .disabled, secureBoot: .reduced),
            allowInsecureOverride: true,
            emit: emitter.emit
        )
        #expect(emitter.text.contains(BootSecurityPolicy.overrideEnvVar))
        #expect(emitter.text.contains("DO NOT serve production"))
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
