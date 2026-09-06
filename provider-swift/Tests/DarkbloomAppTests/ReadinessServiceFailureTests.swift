import Testing
@testable import DarkbloomApp

@Test("A failed diagnostics process does not label Apple silicon or boot security as broken")
@MainActor
func diagnosticsFailureIsSeparateFromHardware() {
    let evaluation = ReadinessEvaluator.unavailable("The installed engine needs an update.")
    #expect(evaluation.phase == .unavailable)
    #expect(evaluation.completedCount == 0)
    #expect(evaluation.items.count == OnboardingFlowModel.readinessItemCount)
    #expect(evaluation.items.allSatisfy { $0.state == .waiting })
    #expect(evaluation.failureMessage == "The installed engine needs an update.")

    let flow = OnboardingFlowModel()
    flow.applyReadiness(evaluation)
    #expect(!flow.canContinue)
    #expect(flow.readinessFailureDetail == evaluation.failureMessage)
    flow.returnToReadinessForSystemCheck()
    #expect(flow.readinessFailureDetail == nil)
    #expect(flow.readinessPhase == .checking)
}
