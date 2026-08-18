import Testing
@testable import DarkbloomApp

@Test("A running scan uses one neutral progress icon regardless of the prior verdict")
@MainActor
func runningDiagnosticPresentationIsNeutral() {
    let healthy = DiagnosticsStore(fixture: .healthy).report
    let blocked = DiagnosticsStore(fixture: .blockedSecurity).report
    let runState = DiagnosticRunState.running(completedChecks: 2, totalChecks: 10)

    let healthyPresentation = DiagnosticsVerdictPresentation(
        report: healthy,
        runState: runState
    )
    let blockedPresentation = DiagnosticsVerdictPresentation(
        report: blocked,
        runState: runState
    )

    #expect(healthyPresentation.icon == "arrow.triangle.2.circlepath")
    #expect(blockedPresentation.icon == healthyPresentation.icon)
    #expect(healthyPresentation.title == "Checking this Mac…")
    #expect(blockedPresentation.title == healthyPresentation.title)
}
