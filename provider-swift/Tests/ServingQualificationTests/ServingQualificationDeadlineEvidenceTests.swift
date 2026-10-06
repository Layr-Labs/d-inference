import Foundation
import Testing

@testable import ProviderCore

@Suite("Qualification proof from actual deadline verdict")
struct ServingQualificationDeadlineEvidenceTests {
    private func decision(serviceUs: Int64 = 10_000_000) -> InferenceProfile {
        var profile = InferenceProfile()
        var decision = DeadlineDecisionProfile()
        decision.verdict = .accepted
        decision.projection = .bounded
        decision.projectedPrefillTokens = 8828
        decision.projectedDecodeTokens = 33
        decision.prefillTps = 500
        decision.decodeTps = 40
        decision.projectedServiceUs = serviceUs
        decision.submitRemainingUs = 14_000_000
        profile.deadlineDecision = decision
        return profile
    }

    private func capture(_ profile: InferenceProfile, id: String? = "reviewed-real-record",
                         first: Double? = 12_000) -> ServingQualificationDeadlineEvidence {
        .capture(profile: profile, reviewedProfileID: id,
            promptWork: PromptWork(source: "exact_contract", promptTokens: 8828, upperBoundTokens: 8828,
                promptContractID: String(repeating: "a", count: 64), modelArtifactHash: String(repeating: "b", count: 64)),
            budgetMilliseconds: 14_369, firstContentMilliseconds: first)
    }

    @Test func distinctReturnedDurationProvesActivationAtUnchangedClock() {
        let evidence = capture(decision())
        #expect(evidence.calibratedPathProven)
        #expect(evidence.legacyWouldReject)
        #expect(evidence.deliveredWithinBudget)
        #expect(evidence.originalBudgetMilliseconds == 14_369)
        #expect(abs((evidence.legacyServiceMilliseconds ?? 0) - 18_481) < 0.000001)
        #expect(evidence.actualServiceMilliseconds == 10_000)
    }

    @Test func fallbackOrRoundingDifferenceNeverProvesActivation() {
        #expect(!capture(decision(serviceUs: 18_481_000)).calibratedPathProven)
        #expect(!capture(decision(serviceUs: 18_480_999)).calibratedPathProven)
        #expect(!capture(decision(), id: nil).calibratedPathProven)
        var missing = decision()
        missing.deadlineDecision?.prefillTps = nil
        #expect(!capture(missing).calibratedPathProven)
    }

    @Test func rejectedOrUnboundedCannotProveAdmission() {
        var rejected = decision()
        rejected.deadlineDecision?.verdict = .deadlineUnreachable
        #expect(!capture(rejected).calibratedPathProven)
        rejected.deadlineDecision?.verdict = .accepted
        rejected.deadlineDecision?.projection = .unbounded
        #expect(!capture(rejected).calibratedPathProven)
    }

    @Test func physicalDeadlineMissRemainsVisibleEvenWithCalibratedAdmission() {
        let late = capture(decision(), first: 14_370)
        #expect(late.calibratedPathProven)
        #expect(!late.deliveredWithinBudget)
        #expect(!capture(decision(), first: nil).deliveredWithinBudget)
    }
}
