import Foundation
@_spi(Benchmarking) import MLXLMCommon
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

/// Recurrent donors retain the first chunk end, the deepest chunk end at or
/// below the coordinator's repeated-prefix hint, and the rolling latest, on
/// real Qwen3.5-9B weights with the production paged assembly and a 2,048
/// token solo stripe. Run with
/// `DARKBLOOM_LIVE_MLX_TESTS=1 DARKBLOOM_LIVE_MLX_QWEN35_CHECKPOINT_RETENTION=1`.
@Suite("Qwen3.5 recurrent checkpoint retention (live)", .serialized)
struct Qwen35CheckpointRetentionLiveTests {
    private static let enabled = LiveInferenceFixtures.liveTestsEnabled
        && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_QWEN35_CHECKPOINT_RETENTION"] == "1"

    /// A donor past 8,192 tokens with a fork hint of 5,120 (a 1,024-stride
    /// coordinator value) keeps 2,048, the chunk end below the hint (4,096)
    /// and 8,192. A fork sharing ~4,300 tokens restores 4,096 and answers as
    /// its cold control; the next turn restores 8,192.
    @Test("a fork hint keeps the chunk end below it beside the first and deepest, and both restore",
          .timeLimit(.minutes(10)), .enabled(if: enabled))
    func forkTargetRetainedAndRestored() async throws {
        let fixture = try await Qwen35CheckpointRetentionFixture()
        do {
            let stripe = Qwen35CheckpointRetentionFixture.stripeTokens
            let donorTokens = fixture.prompts.donor
            let deepest = donorTokens.count / stripe * stripe
            try #require(deepest == 8_192, "fixture geometry: donor \(donorTokens.count) tokens")
            let fork = try fixture.forkPrompt(sharingAtLeast: 4_300)
            let next = try fixture.continuation()
            try #require(next.shared >= deepest, "the next turn must share the donor's deepest chunk end: \(next.shared)")

            let donorStore = try fixture.makeStore()
            let donorBridge = try fixture.makeBridge(store: donorStore)
            let donor = try await run(fixture, bridge: donorBridge, tokens: donorTokens, scope: "tenant-a",
                id: "donor", expectedMarker: Qwen35CheckpointRetentionFixture.releaseMarker,
                donationDemand: .init(repeatedPrefixTokens: 5_120))
            #expect(donor.hitTokens == 0)
            try await requireIdle(donorBridge)
            await donorStore.waitForWritesForTesting()
            let kept = try fixture.positions(scope: "tenant-a", prefixOf: donorTokens)
            #expect(kept.positions == [2_048, 4_096, 8_192],
                    "first chunk end, floor(5,120 / 2,048) x 2,048, deepest")
            #expect(donorStore.stats().filesWritten == 3)
            #expect(donorStore.stats().recurrentCaptureDisarmedChunkChange == 0,
                    "a solo donor's ragged tail is a geometry disarm, not a cap change")
            print("[qwen35-retention] modelHash=\(fixture.modelHash) prompt=\(donorTokens.count) hint=5120 "
                + "positions=\(kept.positions) tensorBytes=\(kept.bytes) "
                + "filesWritten=\(donorStore.stats().filesWritten) bytesWritten=\(donorStore.stats().bytesWritten) "
                + "donorTTFT=\(donor.ttft) donorFinishToDone=\(donor.finishToDone)")
            await donorBridge.shutdown()
            await donorStore.closeAndWait()
            #expect(donorStore.stats().stagedBytesInUse == 0)

            // The fork, on a reconstructed engine over the same files.
            let forkStore = try fixture.makeStore()
            try #require(forkStore.stats().entries == 3, "new store failed to scan donated files")
            let forkBridge = try fixture.makeBridge(store: forkStore)
            let forkHint = fork.shared / PrefixCachePolicy.blockSize * PrefixCachePolicy.blockSize
            let restored = try await run(fixture, bridge: forkBridge, tokens: fork.tokens, scope: "tenant-a",
                id: "fork", expectedMarker: Qwen35CheckpointRetentionFixture.backupMarker,
                donationDemand: .init(repeatedPrefixTokens: forkHint))
            #expect(restored.hitTokens == 4_096, "the fork shares \(fork.shared) tokens; 4,096 is its chunk end")
            #expect(forkStore.stats().stageConsumptions == 1)
            try await requireIdle(forkBridge)
            await forkStore.waitForWritesForTesting()
            let forkKept = try fixture.positions(scope: "tenant-a", prefixOf: fork.tokens)
            let added = forkKept.positions.filter { $0 > 4_096 }
            #expect(forkKept.positions.filter { $0 <= 4_096 } == [2_048, 4_096],
                    "the first and the fork boundary are the donor's files, not rewritten")
            #expect(forkStore.stats().filesWritten == added.count,
                    "the adopter writes only chunk ends above its restore point")
            await forkBridge.shutdown()
            await forkStore.closeAndWait()

            let coldBridge = try fixture.makeBridge(store: nil)
            let cold = try await run(fixture, bridge: coldBridge, tokens: fork.tokens, scope: "tenant-a",
                id: "fork-cache-off", expectedMarker: Qwen35CheckpointRetentionFixture.backupMarker)
            try await requireIdle(coldBridge)
            #expect(restored.text == cold.text, "a restored fork must answer exactly as its cold control")
            print("[qwen35-retention] forkPrompt=\(fork.tokens.count) shared=\(fork.shared) forkHint=\(forkHint) "
                + "hit=\(restored.hitTokens) adopterAdded=\(added) sameText=\(restored.text == cold.text) "
                + "warmTTFT=\(restored.ttft) offTTFT=\(cold.ttft) bytesRead=\(forkStore.stats().bytesRead)")
            await coldBridge.shutdown()

            // The next turn of the same conversation restores the deepest.
            let nextStore = try fixture.makeStore()
            let nextBridge = try fixture.makeBridge(store: nextStore)
            let nextHint = next.shared / PrefixCachePolicy.blockSize * PrefixCachePolicy.blockSize
            let turn = try await run(fixture, bridge: nextBridge, tokens: next.tokens, scope: "tenant-a",
                id: "next-turn", expectedMarker: Qwen35CheckpointRetentionFixture.backupMarker,
                donationDemand: .init(repeatedPrefixTokens: nextHint))
            #expect(turn.hitTokens == 8_192, "the next turn restores the donor's deepest chunk end")
            try await requireIdle(nextBridge)
            await nextStore.waitForWritesForTesting()
            let nextKept = try fixture.positions(scope: "tenant-a", prefixOf: next.tokens)
            #expect(nextKept.positions.filter { $0 <= 8_192 } == [2_048, 4_096, 8_192])
            #expect(nextStore.stats().filesWritten == nextKept.positions.filter { $0 > 8_192 }.count)
            print("[qwen35-retention] nextPrompt=\(next.tokens.count) shared=\(next.shared) nextHint=\(nextHint) "
                + "hit=\(turn.hitTokens) warmTTFT=\(turn.ttft) bytesRead=\(nextStore.stats().bytesRead) "
                + "answer=\(turn.answer.debugDescription)")
            await nextBridge.shutdown()
            await nextStore.closeAndWait()
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    /// A ~6.2k donor with the same fork hint: 4,096 is only one chunk below
    /// its 6,144 deepest, so it is retired unwritten at publication, exactly
    /// as the historical rule drops a target within one stride.
    @Test("a fork target one chunk below the deepest is dropped at publication",
          .timeLimit(.minutes(10)), .enabled(if: enabled))
    func targetOneChunkBelowDeepestIsDropped() async throws {
        let fixture = try await Qwen35CheckpointRetentionFixture()
        do {
            let tokens = try fixture.shortDonor(deepest: 6_144)
            let store = try fixture.makeStore()
            let bridge = try fixture.makeBridge(store: store)
            let donor = try await run(fixture, bridge: bridge, tokens: tokens, scope: "tenant-b",
                id: "short-donor", expectedMarker: Qwen35CheckpointRetentionFixture.releaseMarker,
                donationDemand: .init(repeatedPrefixTokens: 5_120))
            #expect(donor.hitTokens == 0)
            try await requireIdle(bridge)
            await store.waitForWritesForTesting()
            let kept = try fixture.positions(scope: "tenant-b", prefixOf: tokens)
            #expect(kept.positions == [2_048, 6_144], "4,096 is within one chunk of 6,144")
            #expect(store.stats().filesWritten == 2)
            print("[qwen35-retention-adjacent] prompt=\(tokens.count) hint=5120 positions=\(kept.positions) "
                + "tensorBytes=\(kept.bytes) bytesWritten=\(store.stats().bytesWritten)")
            await bridge.shutdown()
            await store.closeAndWait()
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    private struct Output {
        let text: String
        let answer: String
        let hitTokens: Int
        let ttft: Duration
        let finishToDone: Duration
    }

    private func run(_ fixture: Qwen35CheckpointRetentionFixture, bridge: EngineV2Bridge,
                     tokens: [Int], scope: String, id: String, expectedMarker: String,
                     donationDemand: SSDCheckpointDonationDemand? = nil) async throws -> Output {
        let signal = EngineV2RequestUsageSignal()
        let request = ChatCompletionRequest(model: Qwen35CheckpointRetentionFixture.modelID,
            messages: [ChatMessage(role: "user", content: "pre-tokenized fixture")],
            temperature: 0, max_tokens: 48)
        let started = ContinuousClock.now
        let stream = await bridge.submitTokenized(promptTokens: tokens, request: request,
            requestId: id, cacheScope: scope, usageSignal: signal, donationDemand: donationDemand)
        var text = ""
        var firstChunk: ContinuousClock.Instant?
        var lastChunk: ContinuousClock.Instant?
        var done: ContinuousClock.Instant?
        var failure: String?
        var finishReason: String?
        for await event in stream {
            switch event {
            case .chunk(let chunk):
                if firstChunk == nil && !chunk.isEmpty { firstChunk = .now }
                if !chunk.isEmpty { lastChunk = .now }
                text += chunk
            case .info(_, _, _, let reason): finishReason = reason; done = .now
            case .error(let message): failure = message
            case .terminal(_, let message, _, _): failure = message
            }
        }
        let finishToDone = (done ?? .now) - (lastChunk ?? started)
        try #require(failure == nil, "request \(id) failed: \(failure ?? "")")
        try #require(finishReason == "stop", "request \(id) must finish naturally")
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(!answer.isEmpty, "request \(id) produced no answer")
        let normalized = answer.uppercased().trimmingCharacters(in:
            CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`\"'.*")))
        #expect(normalized == expectedMarker,
                "request \(id) must preserve the requested fact: \(answer)")
        let other = expectedMarker == Qwen35CheckpointRetentionFixture.releaseMarker
            ? Qwen35CheckpointRetentionFixture.backupMarker : Qwen35CheckpointRetentionFixture.releaseMarker
        #expect(!answer.uppercased().contains(other),
                "request \(id) must not leak the other marker: \(answer)")
        print("[qwen35-retention-request] id=\(id) hit=\(signal.prefixCacheHitTokens ?? 0) "
            + "ttft=\((firstChunk ?? .now) - started) finishToDone=\(finishToDone) answer=\(answer.debugDescription)")
        return Output(text: text, answer: answer, hitTokens: signal.prefixCacheHitTokens ?? 0,
                      ttft: (firstChunk ?? .now) - started, finishToDone: finishToDone)
    }

    private func requireIdle(_ bridge: EngineV2Bridge) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while true {
            let capacity = await bridge.capacitySnapshot()
            let idle = capacity.activeRequests == 0 && capacity.waitingRequests == 0
                && capacity.kvBytesInUse == 0 && capacity.kvBytesReserved == 0
            if idle { return }
            if ContinuousClock.now >= deadline {
                try #require(idle, "request accounting did not drain before reconstruction")
                return
            }
            try await taskSleep(.milliseconds(10))
        }
    }
}
