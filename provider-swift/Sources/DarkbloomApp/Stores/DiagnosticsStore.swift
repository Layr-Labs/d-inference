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

    init(fixture: DiagnosticsFixture = .healthy) {
        let state = DiagnosticsFixtures.make(fixture)
        report = state.report
        runState = state.runState
    }

    var primaryFix: DiagnosticFix? {
        report.prioritizedFixes.first
    }

    var isScanning: Bool {
        if case .running = runState { return true }
        return false
    }

    func startScan() {
        selectedFixID = nil
        runState = .running(completedChecks: 0, totalChecks: report.checks.count)
    }

    func retryScan() {
        startScan()
    }

    func advanceScan() {
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
        runState = .ready(lastChecked: report.generatedAt)
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

    @discardableResult
    func simulateResolution(fixID: DiagnosticFix.ID) -> Bool {
        guard !isScanning else { return false }
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
}
