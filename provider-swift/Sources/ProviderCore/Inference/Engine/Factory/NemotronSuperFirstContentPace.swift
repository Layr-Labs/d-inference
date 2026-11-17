// Copyright © 2026 Eigen Labs.

import Foundation

/// A Super owner's own pace to first content, and the early refusal it allows.
///
/// A coordinator request may carry the time left for its first content
/// (`first_content_budget_ms`); local, own-machine and `cluster local` requests
/// carry none. The coordinator ends a request whose first content misses that
/// deadline, so a Mac that starts a request it cannot answer in time spends the
/// whole budget and the request is lost. Refused at once as
/// `deadline_unreachable`, the request is re-routed to another Mac within the
/// same budget.
///
/// The evidence is the owner's own, from coordinator requests that ran alone
/// (no other request admitted between their admission and their first chunk
/// or end) with at least `minimumEvidenceTokens` prompt tokens, per `Kind`
/// (decoding images or a video adds its own time), kept for `evidenceWindow`:
/// - an answer: its time from admission to first chunk, per prompt token;
/// - a miss, a request the coordinator cancelled for its first-content
///   timeout before any first chunk: the time from its admission to its
///   forwarded deadline, per prompt token. The coordinator's timer runs on the
///   deadline that budget is cut from, so this bounds its pace from below to
///   within the network delay.
///
/// For a request of one kind, the projected pace is the fastest recent
/// answer's, raised to the lower bound of the two most recent misses once there
/// are two; a miss that a later, faster answer beat no longer counts. A request
/// is refused when its prompt at that pace cannot reach first content before its
/// deadline, unless an answer at least as long came within the time it has left.
/// Without evidence nothing is refused.
struct NemotronSuperFirstContentPace: Sendable, Equatable {
    /// What a request's prompt holds besides text.
    enum Kind: Sendable, Equatable {
        case text, image, video
    }

    struct Sample: Sendable, Equatable {
        let promptTokens: Int
        let kind: Kind
        /// An answer's time to its first chunk; a miss's whole budget.
        let duration: Duration
        let at: ContinuousClock.Instant

        var secondsPerToken: Double { Self.seconds(duration) / Double(promptTokens) }

        static func seconds(_ duration: Duration) -> Double {
            let parts = duration.components
            return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        }
    }

    /// Shorter prompts measure the fixed per-request work more than the
    /// prompt's: their pace would overstate a long prompt's.
    static let minimumEvidenceTokens = 8_192
    /// Evidence describes the Mac's recent load; older samples are ignored
    /// when projecting a pace.
    static let evidenceWindow: Duration = .seconds(900)
    static let samplesKept = 16

    private(set) var answers: [Sample] = []
    private(set) var misses: [Sample] = []

    mutating func recordAnswer(promptTokens: Int, kind: Kind, firstChunkAfter: Duration,
                               at now: ContinuousClock.Instant) {
        guard promptTokens >= Self.minimumEvidenceTokens, firstChunkAfter > .zero else { return }
        Self.append(.init(promptTokens: promptTokens, kind: kind, duration: firstChunkAfter, at: now), to: &answers)
    }

    mutating func recordMiss(promptTokens: Int, kind: Kind, budget: Duration, at now: ContinuousClock.Instant) {
        guard promptTokens >= Self.minimumEvidenceTokens, budget > .zero else { return }
        Self.append(.init(promptTokens: promptTokens, kind: kind, duration: budget, at: now), to: &misses)
    }

    /// Whether a request of `promptTokens` and `kind` with `remaining` until
    /// its deadline cannot reach first content in time. A deadline already
    /// passed always can't.
    func refuses(promptTokens: Int, kind: Kind, remaining: Duration, now: ContinuousClock.Instant) -> Bool {
        guard remaining > .zero else { return true }
        guard promptTokens > 0 else { return false }
        let recentAnswers = recent(answers, kind: kind, now: now)
        if recentAnswers.contains(where: { $0.promptTokens >= promptTokens && $0.duration <= remaining }) {
            return false
        }
        var pace = recentAnswers.map(\.secondsPerToken).min()
        // A miss stops counting once a later answer was faster than its bound.
        let recentMisses = recent(misses, kind: kind, now: now).filter { miss in
            !recentAnswers.contains { $0.at > miss.at && $0.secondsPerToken < miss.secondsPerToken }
        }
        if recentMisses.count >= 2, let bound = recentMisses.suffix(2).map(\.secondsPerToken).min() {
            pace = max(pace ?? 0, bound)
        }
        guard let pace else { return false }
        return Double(promptTokens) * pace > Sample.seconds(remaining)
    }

    /// The kind's samples from the last `evidenceWindow`, oldest first.
    private func recent(_ samples: [Sample], kind: Kind, now: ContinuousClock.Instant) -> [Sample] {
        samples.filter { $0.kind == kind && now - $0.at <= Self.evidenceWindow }
    }

    private static func append(_ sample: Sample, to samples: inout [Sample]) {
        samples.append(sample)
        if samples.count > samplesKept { samples.removeFirst(samples.count - samplesKept) }
    }
}
