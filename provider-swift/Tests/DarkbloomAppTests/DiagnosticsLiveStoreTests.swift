import Foundation
import Testing
@testable import DarkbloomApp

/// Recording/fakeable `DiagnosticsCLIRunning` — never a real subprocess.
final class StubDiagnosticsCLI: DiagnosticsCLIRunning, @unchecked Sendable {
    enum Mode {
        case payload(DoctorJSONReport)
        case error(any Error)
        case hang
    }

    private let lock = NSLock()
    private(set) var callCount = 0
    var mode: Mode {
        get { lock.withLock { modeStorage } }
        set { lock.withLock { modeStorage = newValue } }
    }
    private var modeStorage: Mode

    init(mode: Mode) {
        modeStorage = mode
    }

    func runDoctorJSON() async throws -> DoctorJSONReport {
        lock.withLock { callCount += 1 }
        switch mode {
        case .payload(let report): return report
        case .error(let error): throw error
        case .hang: try await Task.sleep(for: .seconds(3600)); throw CancellationError()
        }
    }
}

@Suite("live diagnostics store (CLI-backed)")
struct DiagnosticsLiveStoreTests {
    private func samplePayload() -> DoctorJSONReport {
        DoctorJSONReport(
            schema: 1,
            version: "0.8.5",
            checks: [
                DoctorJSONReport.Check(
                    id: "runtime.daemon", section: "runtime", title: "daemon",
                    status: "pass", detail: "running", advice: nil),
                DoctorJSONReport.Check(
                    id: "sip", section: "security", title: "sip",
                    status: "warn", detail: "disabled",
                    advice: "boot into Recovery, run `csrutil enable`"),
            ],
            fixes: [
                DoctorJSONReport.Fix(
                    id: "fix-sip", check: "sip", title: "sip",
                    detail: "boot into Recovery, run `csrutil enable`",
                    priority: "recommended"),
            ],
            verdict: DoctorJSONReport.Verdict(status: "warn", failures: 0, warnings: 1)
        )
    }

    /// `performLiveScan` runs in a detached task; poll the MainActor state
    /// until it settles (stubs resolve in milliseconds).
    @MainActor
    private func waitFor(
        _ predicate: @MainActor () -> Bool,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < timeout {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    @Test("A live store boots empty and runs on first open")
    @MainActor
    func firstScanPopulatesTheReport() async {
        let cli = StubDiagnosticsCLI(mode: .payload(samplePayload()))
        let store = DiagnosticsStore(cli: cli)

        #expect(store.isLive)
        #expect(store.runState == .notStarted)
        #expect(store.report.checks.isEmpty)

        store.beginScanIfIdle()
        guard case .running = store.runState else {
            Issue.record("beginScanIfIdle should start the scan; got \(store.runState)")
            return
        }

        #expect(await waitFor { !store.isScanning && store.runState != .notStarted })
        guard case .ready(let lastChecked) = store.runState else {
            Issue.record("expected .ready after a successful scan; got \(store.runState)")
            return
        }
        #expect(Date().timeIntervalSince(lastChecked) < 60)
        #expect(store.report.checks.map(\.id) == ["runtime.daemon", "sip"])
        #expect(store.report.checks[1].severity == .warning)
        // The advice flows through as a routed fix card.
        #expect(store.primaryFix?.id == "fix-sip")
        #expect(store.primaryFix?.action == .openRecoveryInstructions)
        #expect(cli.callCount == 1)

        // A second beginScanIfIdle does NOT re-scan (one auto-run per boot).
        store.beginScanIfIdle()
        #expect(cli.callCount == 1)
    }

    @Test("Missing CLI degrades with guidance, not a fake 'healthy'")
    @MainActor
    func missingCLIProducesGuidanceAndASyntheticReport() async {
        let store = DiagnosticsStore(cli: StubDiagnosticsCLI(mode: .error(DiagnosticsCLIError.cliNotFound)))

        store.retryScan()
        #expect(await waitFor { !store.isScanning })

        guard case .unavailable(let message) = store.runState else {
            Issue.record("expected .unavailable; got \(store.runState)")
            return
        }
        #expect(message.contains("not installed"))
        #expect(message.contains("darkbloom.dev"))
        // The empty report must not claim "everything looks good".
        #expect(store.report.overallVerdict == .blocked)
        #expect(store.report.checks == [
            DiagnosticCheckSummary(
                id: "provider-cli",
                section: .connectivity,
                title: "System check unavailable",
                severity: .failure,
                message: message,
                fix: DiagnosticFix(
                    id: "install-or-update-cli",
                    title: "Install or update the Darkbloom CLI",
                    detail: "The app runs `darkbloom doctor --json` for its system checks; install or update the provider from darkbloom.dev, then run the check again.",
                    priority: .urgent,
                    action: .openSupport
                )
            ),
        ])
    }

    @Test("A stale report survives a later outage")
    @MainActor
    func failedRescanKeepsThePriorReport() async {
        let cli = StubDiagnosticsCLI(mode: .payload(samplePayload()))
        let store = DiagnosticsStore(cli: cli)

        store.startScan()
        #expect(await waitFor { !store.isScanning && store.runState != .notStarted })
        let good = store.report
        #expect(cli.callCount == 1)

        cli.mode = .error(DiagnosticsCLIError.undecodable)
        store.retryScan()
        #expect(await waitFor { cli.callCount == 2 && !store.isScanning })

        guard case .unavailable(let message) = store.runState else {
            Issue.record("expected .unavailable; got \(store.runState)")
            return
        }
        #expect(message.contains("Update the provider"))
        #expect(store.report == good) // the last REAL truth stays on screen
        #expect(cli.callCount == 2)
    }

    @Test("Cancelling a first scan returns to not-started and is safe to retry")
    @MainActor
    func cancelRestoresNotStarted() async {
        let cli = StubDiagnosticsCLI(mode: .hang)
        let store = DiagnosticsStore(cli: cli)

        store.startScan()
        #expect(store.isScanning)
        // Fixture-only nudges must not move a live scan.
        store.advanceScan()
        #expect(store.runState == .running(completedChecks: 0, totalChecks: 1))

        store.cancelScan()
        #expect(store.runState == .notStarted)
        #expect(!store.isScanning)

        // And a retry after cancel re-attempts cleanly.
        cli.mode = .payload(samplePayload())
        store.retryScan()
        #expect(await waitFor { cli.callCount == 2 && !store.isScanning })
        guard case .ready = store.runState else {
            Issue.record("expected .ready; got \(store.runState)")
            return
        }
        #expect(store.report.checks.count == 2)
    }

    @Test("Fixture-only affordances stay off in live mode")
    @MainActor
    func liveModeDisablesSimulation() {
        let store = DiagnosticsStore(cli: StubDiagnosticsCLI(mode: .payload(samplePayload())))
        #expect(store.isLive)
        #expect(!store.simulateResolution(fixID: "fix-sip"))
        // triggerFix still surfaces the action so the view can show guidance.
        #expect(store.triggerFix(id: "fix-sip") == nil) // no report yet → unknown id
    }
}
