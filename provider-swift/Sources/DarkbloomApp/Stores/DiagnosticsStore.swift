import Foundation
import Observation

enum DiagnosticsFixture: String, CaseIterable, Sendable {
    case healthy
    case trustPending
    case blockedSecurity
    case runtimeAttention
    case scanUnavailable
}

enum DiagnosticRunState: Equatable, Sendable {
    /// Live store before the first scan — no truth to show yet.
    case notStarted
    case ready(lastChecked: Date)
    case running(completedChecks: Int, totalChecks: Int)
    case unavailable(message: String)
}

@MainActor
@Observable
final class DiagnosticsStore {
    private(set) var report: DiagnosticReport
    private(set) var runState: DiagnosticRunState
    private(set) var selectedFixID: DiagnosticFix.ID?
    private(set) var launchedFixIDs: Set<DiagnosticFix.ID> = []

    /// nil in fixture mode — the view drives a fake progress timer instead.
    @ObservationIgnored
    private let cli: (any DiagnosticsCLIRunning)?

    @ObservationIgnored
    private var liveScanTask: Task<Void, Never>?

    init(fixture: DiagnosticsFixture = .healthy) {
        let state = DiagnosticsFixtures.make(fixture)
        report = state.report
        runState = state.runState
        cli = nil
    }

    /// Live store: each scan shells out to `darkbloom doctor --json`. Boots
    /// `.notStarted` with an empty report; `DiagnosticsView` starts the first
    /// scan on appear, later runs come from the Run Again button.
    init(cli: any DiagnosticsCLIRunning) {
        report = DiagnosticReport(generatedAt: .distantPast, checks: [])
        runState = .notStarted
        self.cli = cli
    }

    deinit {
        liveScanTask?.cancel()
    }

    /// Live stores own the whole scan in one async task; fixture stores have
    /// the view's timer call `advanceScan()` for a simulated sweep.
    var isLive: Bool { cli != nil }

    var primaryFix: DiagnosticFix? {
        report.prioritizedFixes.first
    }

    var isScanning: Bool {
        if case .running = runState { return true }
        return false
    }

    /// Auto-start hook for the view: fires only for a live store that has
    /// never run.
    func beginScanIfIdle() {
        guard case .notStarted = runState else { return }
        startScan()
    }

    func startScan() {
        guard !isScanning else { return }
        selectedFixID = nil
        if isLive {
            runState = .running(
                completedChecks: 0,
                totalChecks: max(1, report.checks.count)
            )
            liveScanTask = Task { [weak self] in
                await self?.performLiveScan()
            }
        } else {
            runState = .running(completedChecks: 0, totalChecks: report.checks.count)
        }
    }

    func retryScan() {
        startScan()
    }

    /// Advances the SIMULATED scan one check — fixture mode only; a live
    /// scan's progress isn't knowable check-by-check (one subprocess, one
    /// JSON document), so it completes in a single step instead.
    func advanceScan() {
        guard !isLive else { return }
        guard case .running(let completed, let total) = runState else { return }
        let next = min(total, completed + 1)
        if next == total {
            runState = .ready(lastChecked: DiagnosticsFixtures.timestamp)
        } else {
            runState = .running(completedChecks: next, totalChecks: total)
        }
    }

    func cancelScan() {
        guard isScanning else { return }
        if isLive {
            liveScanTask?.cancel()
            liveScanTask = nil
            runState = report.checks.isEmpty
                ? .notStarted
                : .ready(lastChecked: report.generatedAt)
        } else {
            runState = .ready(lastChecked: report.generatedAt)
        }
    }

    @discardableResult
    func triggerFix(id: DiagnosticFix.ID) -> DiagnosticFixAction? {
        guard !isScanning else { return nil }
        guard let fix = report.prioritizedFixes.first(where: { $0.id == id }) else {
            return nil
        }
        selectedFixID = id
        launchedFixIDs.insert(id)
        return fix.action
    }

    /// Preview-only fake resolution — never offered against LIVE reports,
    /// where "resolved" is only real when the CLI says so on the next scan.
    @discardableResult
    func simulateResolution(fixID: DiagnosticFix.ID) -> Bool {
        guard !isLive, !isScanning else { return false }
        guard let checkIndex = report.checks.firstIndex(where: { $0.fix?.id == fixID }) else {
            return false
        }

        let check = report.checks[checkIndex]
        var checks = report.checks
        checks[checkIndex] = DiagnosticCheckSummary(
            id: check.id,
            section: check.section,
            title: check.title,
            severity: .passed,
            message: "Marked resolved in this UI preview. A connected system check will verify the real state.",
            fix: nil
        )

        report = DiagnosticReport(generatedAt: report.generatedAt, checks: checks)
        selectedFixID = nil
        launchedFixIDs.insert(fixID)
        runState = .ready(lastChecked: DiagnosticsFixtures.timestamp)
        return true
    }

    func clearSelectedFix() {
        selectedFixID = nil
    }

    // MARK: - Live scanning

    private func performLiveScan() async {
        guard let cli else { return }
        do {
            let payload = try await cli.runDoctorJSON()
            guard !Task.isCancelled else { return }
            let mapped = DiagnosticReport(doctor: payload, generatedAt: Date())
            report = mapped
            // Cards from a superseded report must not linger as "launched".
            launchedFixIDs = []
            runState = .ready(lastChecked: mapped.generatedAt)
        } catch is CancellationError {
            // cancelScan() already restored a usable state.
        } catch {
            guard !Task.isCancelled else { return }
            applyDegraded(error)
        }
    }

    /// A live scan that can't produce a report degrades honestly: the prior
    /// report STAYS when there is one (its checks were real), and a first-run
    /// outage builds a synthetic report so the empty state can't read as
    /// "all healthy". Either way the scan bar shows the guidance.
    private func applyDegraded(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if report.checks.isEmpty {
            report = DiagnosticReport(generatedAt: Date(), checks: [
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
        runState = .unavailable(message: message)
    }
}
