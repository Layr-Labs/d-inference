import Foundation
import ProviderAppAttest
import Testing
@testable import ProviderCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite("App Attest process probe")
struct AppAttestProcessProbeTests {
    @Test func bootSecurityProbesRunOncePerProcessAndConsoleNameIsNeverSent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let probes = Counter()
        let start = ProviderProcessRun.StartContext(processStartedAt: 1_700, previousExit: .clean, startReason: .launchd)
        let probe = AppAttestProcessProbe(
            pushHistory: APNsPushHistoryStore(directory: dir),
            probeBootSecurity: { probes.increment(); return .init(sipEnabled: true, authenticatedRoot: nil) },
            consoleUser: { "alice" },
            preflight: { AppAttestPreflight(bundlePathClass: .userInstall) },
            deviceTokenPresent: { false },
            startContext: { start },
            now: { Date(timeIntervalSince1970: 2_000) })
        let first = probe.diagnostics()
        _ = probe.diagnostics()
        #expect(probes.count == 1)
        #expect(first.sipEnabled == true)
        #expect(first.authenticatedRoot == nil, "probe failure is omitted, not sent as false")
        #expect(first.consoleUserActive == true)
        #expect(first.processStartedAt == 1_700)
        #expect(first.startReason == .launchd)
        #expect(first.pushHistory?.deviceTokenPresent == false)
        let wire = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        #expect(!wire.contains("alice"))
    }

    @Test func loginWindowIsNotAConsoleUserAndSIPMapping() {
        #expect(!AttestationReadiness.isRealConsoleUser("loginwindow"))
        #expect(!AttestationReadiness.isRealConsoleUser(nil))
        #expect(AppAttestProcessProbe.BootSecurity.sip(.enabled) == true)
        #expect(AppAttestProcessProbe.BootSecurity.sip(.enabledWithCustomConfiguration(disabledProtections: ["x"])) == false)
        #expect(AppAttestProcessProbe.BootSecurity.sip(.unavailable(reason: "x")) == nil)
    }

    @Test func authenticatedRootTriStateOmitsUnreadableProbe() {
        let failing = SecurityCommandRunner { _, _ in SecurityCommandResult(terminationStatus: 1) }
        #expect(authenticatedRootStatus(runner: failing) == nil)
        #expect(checkAuthenticatedRootEnabled(runner: failing) == false, "legacy boolean keeps its fail-closed meaning")
        let enabled = SecurityCommandRunner { _, _ in SecurityCommandResult(terminationStatus: 0, stdout: "Authenticated Root status: enabled") }
        #expect(authenticatedRootStatus(runner: enabled) == true)
    }
}
