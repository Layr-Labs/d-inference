import Testing
@testable import DarkbloomApp

@Test("A healthy report has no unresolved work")
@MainActor
func healthyDiagnosticsHaveNoFixes() {
    let store = DiagnosticsStore(fixture: .healthy)

    #expect(store.report.overallVerdict == .healthy)
    #expect(store.report.unresolvedChecks.isEmpty)
    #expect(store.report.prioritizedFixes.isEmpty)
    #expect(store.primaryFix == nil)
}

@Test("Failures determine the overall verdict and urgent fixes precede recommendations")
@MainActor
func blockedDiagnosticsPrioritizeFixes() {
    let store = DiagnosticsStore(fixture: .blockedSecurity)
    let fixes = store.report.prioritizedFixes

    #expect(store.report.overallVerdict == .blocked)
    #expect(fixes.count == 3)
    #expect(fixes[0].priority == .urgent)
    #expect(fixes[1].priority == .urgent)
    #expect(fixes[2].id == "install-update")
    #expect(store.report.unresolvedChecks.first?.severity == .failure)
}

@Test("Pending MDM trust is attention, not a healthy or fully offline state")
@MainActor
func pendingTrustOffersEnrollment() {
    let store = DiagnosticsStore(fixture: .trustPending)

    #expect(store.report.overallVerdict == .attention)
    #expect(store.primaryFix?.id == "finish-enrollment")
    #expect(store.triggerFix(id: "finish-enrollment") == .openEnrollment)
    #expect(store.selectedFixID == "finish-enrollment")
    #expect(store.launchedFixIDs.contains("finish-enrollment"))

    store.clearSelectedFix()
    #expect(store.selectedFixID == nil)
}

@Test("Runtime recovery is prioritized ahead of model and reporting advice")
@MainActor
func runtimeFailurePrioritizesRestart() {
    let store = DiagnosticsStore(fixture: .runtimeAttention)

    #expect(store.report.overallVerdict == .blocked)
    #expect(store.primaryFix?.id == "restart-provider")
    #expect(store.triggerFix(id: "restart-provider") == .restartProvider)
    #expect(store.triggerFix(id: "redownload-model") == .redownloadModel(
        modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
    ))
}

@Test("Diagnostic scans advance deterministically to a fixed completed state")
@MainActor
func diagnosticRunProgressIsDeterministic() {
    let store = DiagnosticsStore(fixture: .healthy)
    let count = store.report.checks.count

    store.startScan()
    #expect(store.runState == .running(completedChecks: 0, totalChecks: count))

    for _ in 0 ..< count {
        store.advanceScan()
    }

    guard case .ready = store.runState else {
        Issue.record("A complete scan should return to ready")
        return
    }
}

@Test("An unavailable remote scan can be retried without replacing its last report")
@MainActor
func unavailableScanCanRetry() {
    let store = DiagnosticsStore(fixture: .scanUnavailable)
    let previousReport = store.report

    guard case .unavailable = store.runState else {
        Issue.record("Expected the unavailable fixture")
        return
    }
    #expect(store.report.overallVerdict == .blocked)

    store.retryScan()
    #expect(store.runState == .running(
        completedChecks: 0,
        totalChecks: previousReport.checks.count
    ))
    #expect(store.report == previousReport)
}

@Test("Preview fixes resolve the matching check and recompute the verdict")
@MainActor
func previewFixResolutionUpdatesReport() {
    let store = DiagnosticsStore(fixture: .trustPending)

    #expect(store.triggerFix(id: "finish-enrollment") == .openEnrollment)
    #expect(store.simulateResolution(fixID: "finish-enrollment"))
    #expect(store.report.overallVerdict == .healthy)
    #expect(store.report.prioritizedFixes.isEmpty)
    #expect(store.report.checks.first { $0.id == "network-trust" }?.severity == .passed)
    #expect(store.selectedFixID == nil)
}

@Test("Scanning blocks stale fix actions and cancellation restores a usable state")
@MainActor
func diagnosticScanCancellationIsSafe() {
    let store = DiagnosticsStore(fixture: .trustPending)
    let originalReport = store.report

    store.startScan()
    store.advanceScan()
    #expect(store.isScanning)
    #expect(store.triggerFix(id: "finish-enrollment") == nil)
    #expect(!store.simulateResolution(fixID: "finish-enrollment"))

    store.cancelScan()
    guard case .ready = store.runState else {
        Issue.record("Cancelling a preview scan should restore the prior completed state")
        return
    }
    #expect(store.report == originalReport)
}
