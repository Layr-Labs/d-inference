import Foundation
import MLXLMCommon

/// Actor-owned permission for one small real request to renew expired cold
/// prefill evidence. This is an exploration policy, never a predicted rate.
/// The caller must hold an exclusive whole-Mac lease until engine retirement.
struct PrefillEvidenceRecovery {
    static let maximumPromptTokens = 1_024
    static let failureBackoff: Duration = .seconds(120)

    private(set) var owner: String?
    private(set) var evidenceGuard: CBv2FirstContentEvidenceGuard?
    private var measured = false
    private var submitted = false
    private var retryAfter: ContinuousClock.Instant?

    func available(at now: ContinuousClock.Instant = .now) -> Bool {
        owner == nil && (retryAfter.map { now >= $0 } ?? true)
    }

    mutating func acquire(_ id: String, evidenceGuard: CBv2FirstContentEvidenceGuard?) {
        precondition(owner == nil)
        owner = id
        self.evidenceGuard = evidenceGuard
        measured = false
        submitted = false
    }

    mutating func observe(_ id: String) {
        if owner == id { measured = true }
    }

    mutating func beginSubmission(_ id: String) {
        if owner == id { submitted = true }
    }

    mutating func bindEvidenceGuard(_ guardValue: CBv2FirstContentEvidenceGuard?, ownerID: String) {
        guard owner == ownerID else { return }
        // Losing exclusivity at the final boundary withdraws exploration and
        // still marks its eventual receipt contended. A missing guard must not
        // look like an ordinary request with no isolation requirement.
        let boundGuard = guardValue ?? CBv2FirstContentEvidenceGuard()
        if guardValue == nil { boundGuard.invalidate() }
        evidenceGuard = boundGuard
    }

    /// A prompt receipt may arrive before the answer terminates. Only actual
    /// retirement (or refusal before submit) releases this permission.
    mutating func retire(_ id: String, at now: ContinuousClock.Instant = .now) {
        guard owner == id else { return }
        if measured { retryAfter = nil }
        else if submitted { retryAfter = now.advanced(by: Self.failureBackoff) }
        owner = nil
        evidenceGuard = nil
        measured = false
        submitted = false
    }
}
