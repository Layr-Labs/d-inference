// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// The Super owner gathers first-content evidence only from coordinator
/// requests that ran alone, and refuses at once only a request that carries a
/// forwarded deadline.
struct NemotronSuperFirstContentRefusalTests {
    private typealias Owner = NemotronSuperLocalBridgeBuilder.Owner
    private typealias Progress = Owner.LocalRequestProgress

    /// A request of `kind` admitted at `start` with `budget` to its deadline
    /// (nil: a local or own-machine request), rendered to `tokens`, that ends
    /// at `end`, cancelled for the coordinator's first-content timeout or not,
    /// with its first chunk at `firstChunk` if any. The admission is returned
    /// however it ends, a refusal included.
    private static func request(_ owner: Owner, tokens: Int, kind: NemotronSuperFirstContentPace.Kind = .image,
                                start: ContinuousClock.Instant, budget: Duration?, firstChunk: Duration? = nil,
                                end: Duration, timedOut: Bool = false) throws {
        #expect(owner.admitLocalRequest())
        let progress = Progress(isMedia: kind != .text)
        owner.beginLocalRequest(progress, firstContentDeadline: budget.map { start + $0 }, now: start)
        var refused = true
        defer { owner.finishLocalRequest(progress, firstContentTimedOut: !refused && timedOut, now: start + end) }
        try owner.admitFirstContent(progress, kind: kind, promptTokens: tokens, now: start)
        refused = false
        if let firstChunk { owner.noteLocalFirstChunk(progress, now: start + firstChunk) }
    }

    /// Two requests the coordinator cancelled for their first-content timeout
    /// refuse a longer one at once, as `deadline_unreachable`; a shorter one
    /// that fits is admitted, text is untouched by image evidence, and a request
    /// with no forwarded deadline (local, own Mac) never is refused.
    @Test(.timeLimit(.minutes(1))) func aloneMissesRefuseALongerRequestAtOnce() async throws {
        let (owner, close) = try await Self.owner()
        #expect(owner.refusesUnreachableFirstContent)
        let t0 = ContinuousClock.now
        try Self.request(owner, tokens: 12_000, start: t0, budget: .seconds(24), end: .seconds(24), timedOut: true)
        // The coordinator's timer may fire before the Mac's own deadline: still a miss.
        try Self.request(owner, tokens: 25_000, start: t0, budget: .milliseconds(37_500),
                         end: .seconds(36), timedOut: true)
        #expect(owner.firstContentEvidence.misses.count == 2)
        // 1.5 ms a token at least: 25K need 37.5 s.
        #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            try Self.request(owner, tokens: 25_000, start: t0, budget: .seconds(36), end: .zero)
        }
        // A refusal is no miss; a shorter prompt fits; text has no media evidence.
        #expect(owner.firstContentEvidence.misses.count == 2)
        try Self.request(owner, tokens: 12_000, start: t0, budget: .seconds(23), firstChunk: .seconds(5), end: .seconds(9))
        try Self.request(owner, tokens: 25_000, kind: .text, start: t0, budget: .seconds(20), firstChunk: .seconds(5),
                         end: .seconds(9))
        // No forwarded deadline: never refused.
        try Self.request(owner, tokens: 200_000, start: t0, budget: nil, end: .seconds(1))
        try await close()
    }

    /// Only the coordinator's first-content-timeout cancel of a coordinator
    /// request is a miss: any other end at or past the deadline, a timeout
    /// after a first chunk, and a local request's answer are no evidence.
    @Test(.timeLimit(.minutes(1))) func onlyAFirstContentTimeoutIsAMiss() async throws {
        let (owner, close) = try await Self.owner()
        let t0 = ContinuousClock.now
        try Self.request(owner, tokens: 20_000, start: t0, budget: .seconds(20), end: .seconds(21), timedOut: false)
        try Self.request(owner, tokens: 20_000, start: t0, budget: nil, end: .seconds(21), timedOut: true)
        try Self.request(owner, tokens: 20_000, start: t0, budget: nil, firstChunk: .seconds(30), end: .seconds(40))
        #expect(owner.firstContentEvidence == NemotronSuperFirstContentPace())
        // Timed out after its first chunk: its answer counts, no miss.
        try Self.request(owner, tokens: 20_000, start: t0, budget: .seconds(20), firstChunk: .seconds(5),
                         end: .seconds(21), timedOut: true)
        #expect(owner.firstContentEvidence.misses.isEmpty)
        #expect(owner.firstContentEvidence.answers.map(\.promptTokens) == [20_000])
        try await close()
    }

    /// An answer that ran alone records its pace: 20K in 10 s is 0.5 ms a
    /// token, too slow for 40K in 19 s and fast enough in 21 s.
    @Test(.timeLimit(.minutes(1))) func anAloneAnswerRecordsItsPace() async throws {
        let (owner, close) = try await Self.owner()
        let t0 = ContinuousClock.now
        try Self.request(owner, tokens: 20_000, start: t0, budget: .seconds(40), firstChunk: .seconds(10), end: .seconds(30))
        #expect(owner.firstContentEvidence.answers.map(\.promptTokens) == [20_000])
        #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            try Self.request(owner, tokens: 40_000, start: t0, budget: .seconds(19), end: .zero)
        }
        try Self.request(owner, tokens: 40_000, start: t0, budget: .seconds(21), firstChunk: .seconds(1), end: .seconds(2))
        try await close()
    }

    /// A request admitted while another was in flight, or followed by one
    /// before its first chunk, is no evidence: the other work slowed it.
    @Test(.timeLimit(.minutes(2))) func overlappingRequestsAreNoEvidence() async throws {
        let (owner, close) = try await Self.owner(environment: [NemotronSuperLocalBridgeBuilder.maxConcurrentKey: "2"])
        #expect(owner.maximumLocalRequests == 2)
        let t0 = ContinuousClock.now, deadline = t0 + .seconds(20)
        let first = Progress(isMedia: true), second = Progress(isMedia: false)
        #expect(owner.admitLocalRequest())
        owner.beginLocalRequest(first, firstContentDeadline: deadline, now: t0)
        try owner.admitFirstContent(first, kind: .image, promptTokens: 20_000, now: t0)
        #expect(owner.admitLocalRequest())
        owner.beginLocalRequest(second, firstContentDeadline: deadline, now: t0)
        try owner.admitFirstContent(second, kind: .text, promptTokens: 20_000, now: t0)
        owner.noteLocalFirstChunk(second, now: t0 + .seconds(2))
        for progress in [first, second] { owner.finishLocalRequest(progress, firstContentTimedOut: true, now: deadline) }
        #expect(owner.firstContentEvidence == NemotronSuperFirstContentPace())
        try await close()
    }

    /// An off word for `DARKBLOOM_NEMOTRON_SUPER_FIRST_CONTENT_REFUSAL` starts
    /// every request, as 0.10.14 did; the LaunchAgent forwards the switch.
    @Test(.timeLimit(.minutes(1))) func theKillSwitchStartsEveryRequest() async throws {
        let key = NemotronSuperLocalBridgeBuilder.firstContentRefusalKey
        #expect(key == "DARKBLOOM_NEMOTRON_SUPER_FIRST_CONTENT_REFUSAL")
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        for value in ["off", " 0 ", "False", "no", "none", "disabled"] {
            #expect(!NemotronSuperLocalBridgeBuilder.firstContentRefusalEnabled(value), "\(value)")
        }
        for value in [nil, "", "on", "1"] as [String?] {
            #expect(NemotronSuperLocalBridgeBuilder.firstContentRefusalEnabled(value), "\(String(describing: value))")
        }
        let (owner, close) = try await Self.owner(environment: [key: "off"])
        #expect(!owner.refusesUnreachableFirstContent)
        let t0 = ContinuousClock.now
        for _ in 0 ..< 2 {
            try Self.request(owner, tokens: 12_000, start: t0, budget: .seconds(24), end: .seconds(24), timedOut: true)
        }
        #expect(owner.firstContentEvidence.misses.count == 2)
        try Self.request(owner, tokens: 100_000, start: t0, budget: .seconds(1), end: .zero)
        try await close()
    }
}

extension NemotronSuperFirstContentRefusalTests {
    /// The synthetic owner (`SuperInstalledFixture`, or its latent-MoE target
    /// for a batched owner) and its teardown.
    private static func owner(environment: [String: String] = [:]) async throws
        -> (Owner, @Sendable () async throws -> Void) {
        let batched = environment[NemotronSuperLocalBridgeBuilder.maxConcurrentKey] != nil
        let (installed, construction, _) = try batched
            ? { let f = try SuperMTPInstalledFixture().make(); return (f.installed, f.construction, f.residency) }()
            : SuperInstalledFixture().make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: .max) })
        // A batched owner needs a grant for both requests' fixed bytes.
        let kvBytes = batched ? 8 << 30 : 2 << 30
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-first-content",
            weightBytes: UInt64(installed.receipt.payloadBytes), minimumKVBytes: UInt64(kvBytes)))
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: installed,
            tokenizer: TokenizerHandle(SuperTokenTextTokenizer()), eosTokenIDs: [],
            sizing: .init(weightsBytes: installed.receipt.payloadBytes,
                fp16KVBytesPerToken: 64, maxContextLength: 64, defaultMaxTokens: 2),
            kvBytesCapacity: kvBytes, kvBudget: budget, loadLease: lease,
            construction: construction, environment: environment)
        return (owner, {
            try await owner.closeAfterDrain()
            #expect(await budget.finishPendingLoad(lease))
        })
    }
}
