import MLXLMCommon

/// Real cumulative engine counters sampled outside the measured interval.
/// Qualification requires driver work during this request, not merely an
/// installed/configured assistant. Accepted zero remains a valid rejection.
struct ModelPrefixBenchmarkMTPObservation: Codable, Sendable {
    let requested: Bool
    let activeBefore: Bool
    let activeAfter: Bool
    let verificationMode: String?
    let rounds: Int
    let draftedTokens: Int
    let acceptedTokens: Int
    let emittedTokens: Int
    let serialVerificationRounds: Int
    let rectangularVerificationRounds: Int
    let seedSteps: Int
    let qualified: Bool
    let qualificationFailure: String?

    init(requested: Bool, before: CBv2MTPMetrics?, after: CBv2MTPMetrics?) {
        self.requested = requested
        activeBefore = before?.active == true
        activeAfter = after?.active == true
        verificationMode = after?.verificationMode.rawValue
        rounds = (after?.rounds ?? 0) - (before?.rounds ?? 0)
        draftedTokens = (after?.draftedTokens ?? 0) - (before?.draftedTokens ?? 0)
        acceptedTokens = (after?.acceptedTokens ?? 0) - (before?.acceptedTokens ?? 0)
        emittedTokens = (after?.emittedTokens ?? 0) - (before?.emittedTokens ?? 0)
        serialVerificationRounds = (after?.serialVerificationRounds ?? 0)
            - (before?.serialVerificationRounds ?? 0)
        rectangularVerificationRounds = (after?.rectangularVerificationRounds ?? 0)
            - (before?.rectangularVerificationRounds ?? 0)
        seedSteps = (after?.seedSteps ?? 0) - (before?.seedSteps ?? 0)
        let failure: String?
        if !requested {
            failure = before == nil && after == nil ? nil : "unexpected_active_engine"
        } else if !activeBefore || !activeAfter {
            failure = "inactive_engine"
        } else if [rounds, draftedTokens, acceptedTokens, emittedTokens,
                   serialVerificationRounds, rectangularVerificationRounds, seedSteps]
            .contains(where: { $0 < 0 }) {
            failure = "counter_regression"
        } else if rounds == 0 || draftedTokens == 0 || emittedTokens == 0
            || serialVerificationRounds + rectangularVerificationRounds == 0 {
            failure = "no_driver_work"
        } else {
            failure = nil
        }
        qualificationFailure = failure
        qualified = failure == nil
    }
}
