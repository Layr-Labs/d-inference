// Copyright © 2026 Eigen Labs.

import Foundation
import Testing
@testable import ProviderCore

/// The Super owner's first-content pace: it refuses only what its own recent
/// evidence of the same kind says cannot reach first content before the deadline.
struct NemotronSuperFirstContentPaceTests {
    private typealias Pace = NemotronSuperFirstContentPace
    private let now = ContinuousClock.now

    @Test func withoutEvidenceNothingIsRefusedButAPassedDeadline() {
        let pace = Pace()
        #expect(!pace.refuses(promptTokens: 200_000, kind: .image, remaining: .milliseconds(1), now: now))
        #expect(pace.refuses(promptTokens: 10, kind: .text, remaining: .zero, now: now))
        #expect(pace.refuses(promptTokens: 10, kind: .image, remaining: .seconds(-1), now: now))
    }

    /// An answer's pace projects a longer prompt: 20K tokens in 10 s is 0.5 ms
    /// a token, so 40K need 20 s.
    @Test func anAnswerProjectsALongerPrompt() {
        var pace = Pace()
        pace.recordAnswer(promptTokens: 20_000, kind: .image, firstChunkAfter: .seconds(10), at: now)
        #expect(!pace.refuses(promptTokens: 40_000, kind: .image, remaining: .seconds(21), now: now))
        #expect(pace.refuses(promptTokens: 40_000, kind: .image, remaining: .seconds(19), now: now))
        // The fastest recent answer sets the pace; a slower one does not.
        pace.recordAnswer(promptTokens: 20_000, kind: .image, firstChunkAfter: .seconds(30), at: now)
        #expect(!pace.refuses(promptTokens: 40_000, kind: .image, remaining: .seconds(21), now: now))
    }

    /// One miss may be a fluke; the two most recent bound the pace from below,
    /// at the lower of their two rates.
    @Test func twoMissesBoundThePace() {
        var pace = Pace()
        // 12K tokens missed a 24 s deadline: at least 2 ms a token.
        pace.recordMiss(promptTokens: 12_000, kind: .image, budget: .seconds(24), at: now)
        #expect(!pace.refuses(promptTokens: 25_000, kind: .image, remaining: .seconds(36), now: now))
        // 25K missed 37.5 s: at least 1.5 ms a token. The bound is 1.5 ms.
        pace.recordMiss(promptTokens: 25_000, kind: .image, budget: .milliseconds(37_500), at: now)
        #expect(pace.refuses(promptTokens: 25_000, kind: .image, remaining: .seconds(36), now: now))
        #expect(pace.refuses(promptTokens: 40_000, kind: .image, remaining: .seconds(55), now: now))
        #expect(!pace.refuses(promptTokens: 12_000, kind: .image, remaining: .seconds(23), now: now))
    }

    /// Text, images and video keep their own evidence: decoding images or a
    /// video is no text pace, and a video's frame decoding is no image's.
    @Test func evidenceOfOneKindNeverRefusesAnother() {
        var pace = Pace()
        pace.recordMiss(promptTokens: 12_000, kind: .video, budget: .seconds(24), at: now)
        pace.recordMiss(promptTokens: 25_000, kind: .video, budget: .milliseconds(37_500), at: now)
        #expect(pace.refuses(promptTokens: 25_000, kind: .video, remaining: .seconds(20), now: now))
        #expect(!pace.refuses(promptTokens: 25_000, kind: .image, remaining: .seconds(20), now: now))
        #expect(!pace.refuses(promptTokens: 25_000, kind: .text, remaining: .seconds(20), now: now))
        pace.recordAnswer(promptTokens: 20_000, kind: .text, firstChunkAfter: .seconds(10), at: now)
        #expect(pace.refuses(promptTokens: 40_000, kind: .text, remaining: .seconds(19), now: now))
        #expect(!pace.refuses(promptTokens: 40_000, kind: .image, remaining: .seconds(19), now: now))
        #expect(pace.refuses(promptTokens: 25_000, kind: .video, remaining: .seconds(20), now: now))
    }

    /// A coordinator cancel for the first-content timeout (or late content
    /// after it) is what the owner counts as a miss; a cancel for any other
    /// reason, a paid one, or one without a reason is not.
    @Test func onlyTheFirstContentTimeoutCancelIsAMissCause() {
        func cancel(_ code: String, paid: Bool = false) -> InferenceEarlyEndCause {
            .coordinatorCancel(CoordinatorCancelReason(code: code, paid: paid))
        }
        #expect(cancel("first_chunk_timeout").isFirstContentTimeout)
        #expect(cancel("late_content").isFirstContentTimeout)
        for cause in [cancel("hedge_loser"), cancel("client_gone_pre"), cancel("first_chunk_timeout", paid: true),
                      .coordinatorCancel(nil), .connectionLost, .stoppedOnThisMac] {
            #expect(!cause.isFirstContentTimeout, "\(cause)")
        }
        var counts = EndedEarlyCounts()
        counts.add(cancel("first_chunk_timeout"))
        counts.add(cancel("late_content"))
        counts.add(cancel("hedge_loser"))
        #expect(counts.startedTooLate == 2 && counts.anotherMacFirst == 1 && counts.total == 3)
    }

    /// A miss that a later answer beat (a faster pace than the miss's bound)
    /// describes a load that has passed: it no longer counts. An earlier answer
    /// does not lift it.
    @Test func aLaterFasterAnswerSupersedesOlderMisses() {
        var pace = Pace()
        let t0 = now - .seconds(600), t1 = now - .seconds(300)
        pace.recordMiss(promptTokens: 12_000, kind: .image, budget: .seconds(24), at: t0)
        pace.recordMiss(promptTokens: 25_000, kind: .image, budget: .milliseconds(37_500), at: t0)
        pace.recordAnswer(promptTokens: 10_000, kind: .image, firstChunkAfter: .seconds(5), at: t0 - .seconds(1))
        #expect(pace.refuses(promptTokens: 25_000, kind: .image, remaining: .seconds(20), now: now))
        // 0.5 ms a token, after both misses: 25K need 12.5 s.
        pace.recordAnswer(promptTokens: 10_000, kind: .image, firstChunkAfter: .seconds(5), at: t1)
        #expect(!pace.refuses(promptTokens: 25_000, kind: .image, remaining: .seconds(20), now: now))
        #expect(pace.refuses(promptTokens: 25_000, kind: .image, remaining: .seconds(12), now: now))
    }

    /// An answer at least as long that came within the time left proves the
    /// request can make it, whatever the misses say.
    @Test func aLongerAnswerWithinTheTimeLeftWins() {
        var pace = Pace()
        let earlier = now - .seconds(60)
        pace.recordAnswer(promptTokens: 50_000, kind: .image, firstChunkAfter: .seconds(20), at: earlier)
        pace.recordMiss(promptTokens: 10_000, kind: .image, budget: .seconds(20), at: now)
        pace.recordMiss(promptTokens: 10_000, kind: .image, budget: .seconds(20), at: now)
        #expect(!pace.refuses(promptTokens: 45_000, kind: .image, remaining: .seconds(25), now: now))
        #expect(pace.refuses(promptTokens: 45_000, kind: .image, remaining: .seconds(19), now: now))
        #expect(pace.refuses(promptTokens: 60_000, kind: .image, remaining: .seconds(25), now: now))
    }

    /// Short prompts measure the fixed per-request work, not the prompt: no evidence.
    @Test func shortPromptsAreNoEvidence() {
        var pace = Pace()
        let short = Pace.minimumEvidenceTokens - 1
        pace.recordAnswer(promptTokens: short, kind: .text, firstChunkAfter: .seconds(60), at: now)
        pace.recordMiss(promptTokens: short, kind: .text, budget: .seconds(60), at: now)
        pace.recordMiss(promptTokens: short, kind: .text, budget: .seconds(60), at: now)
        #expect(pace.answers.isEmpty && pace.misses.isEmpty)
        #expect(!pace.refuses(promptTokens: 100_000, kind: .text, remaining: .seconds(1), now: now))
    }

    /// Evidence describes recent load: it expires, and only the newest samples are kept.
    @Test func evidenceExpiresAndIsBounded() {
        var pace = Pace()
        let old = now - Pace.evidenceWindow - .seconds(1)
        pace.recordMiss(promptTokens: 10_000, kind: .text, budget: .seconds(100), at: old)
        pace.recordMiss(promptTokens: 10_000, kind: .text, budget: .seconds(100), at: old)
        pace.recordAnswer(promptTokens: 10_000, kind: .text, firstChunkAfter: .seconds(100), at: old)
        #expect(!pace.refuses(promptTokens: 10_000, kind: .text, remaining: .seconds(1), now: now))
        for _ in 0 ..< Pace.samplesKept + 4 {
            pace.recordAnswer(promptTokens: 10_000, kind: .text, firstChunkAfter: .seconds(1), at: now)
        }
        #expect(pace.answers.count == Pace.samplesKept && pace.misses.count == 2)
    }
}
