import Foundation

@testable import ProviderCore

/// Proof from the actual atomic verdict, not a pre-submit policy reconstruction.
/// The SDK has exactly two service conversions. A bounded returned duration
/// distinct from its recorded legacy inputs proves the calibrated conversion
/// was selected. Indistinguishable durations deliberately remain unproven.
struct ServingQualificationDeadlineEvidence: Codable, Sendable {
    let reviewedProfileID: String?
    let promptWork: PromptWork?
    let originalBudgetMilliseconds: Int
    let legacyServiceMilliseconds: Double?
    let actualServiceMilliseconds: Double?
    let submitRemainingMilliseconds: Double?
    let calibratedPathProven: Bool
    let legacyWouldReject: Bool
    let deliveredWithinBudget: Bool

    static func capture(profile: InferenceProfile, reviewedProfileID: String?, promptWork: PromptWork?,
                        budgetMilliseconds: Int, firstContentMilliseconds: Double?) -> Self {
        let decision = profile.deadlineDecision
        func seconds(_ tokens: Int64?, _ rate: Double?) -> Double? {
            guard let tokens, tokens >= 0 else { return nil }
            if tokens == 0 { return 0 }
            guard let rate, rate.isFinite, rate > 0 else { return nil }
            let value = Double(tokens) / rate
            return value.isFinite ? value : nil
        }
        let legacy = seconds(decision?.projectedPrefillTokens, decision?.prefillTps).flatMap { prefill in
            seconds(decision?.projectedDecodeTokens, decision?.decodeTps).map { (prefill + $0) * 1000 }
        }
        let actual = decision?.projectedServiceUs.map { Double($0) / 1000 }
        let remaining = decision?.submitRemainingUs.map { Double($0) / 1000 }
        // The profiler truncates service duration to microseconds. A full
        // millisecond tolerance is deliberately larger than conversion noise.
        let distinct = legacy.flatMap { old in actual.map { abs(old - $0) > 1 } } ?? false
        return .init(reviewedProfileID: reviewedProfileID, promptWork: promptWork,
            originalBudgetMilliseconds: budgetMilliseconds, legacyServiceMilliseconds: legacy,
            actualServiceMilliseconds: actual, submitRemainingMilliseconds: remaining,
            calibratedPathProven: reviewedProfileID != nil && promptWork != nil
                && decision?.projection == .bounded && decision?.verdict == .accepted && distinct,
            legacyWouldReject: legacy.flatMap { old in remaining.map { old > $0 } } ?? false,
            deliveredWithinBudget: firstContentMilliseconds.map {
                $0.isFinite && $0 >= 0 && $0 <= Double(budgetMilliseconds)
            } ?? false)
    }
}

final class QualificationStreamProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var content = false
    private var terminal = false
    var contentSeen: Bool { lock.withLock { content } }
    var finished: Bool { lock.withLock { terminal } }
    func observeContent() { lock.withLock { content = true } }
    func finish() { lock.withLock { terminal = true } }
}
