import Foundation
@_spi(Benchmarking) import MLXLMCommon
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

/// Recurrent donors capture at every aligned range end whatever chunk
/// produced it, and retain the first boundary, the deepest boundary at or
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
            #expect(donorStore.stats().recurrentCaptureDisarmedPacked == 0,
                    "a solo donor's ragged tail is a geometry disarm, not a packed one")
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

    /// A ~6.2k donor with the same fork hint: 4,096 is one 2,048 chunk
    /// below its 6,144 deepest, past the fixed 1,024-token adjacency every
    /// layout uses, so it is kept beside the first and the deepest.
    @Test("a fork target one 2,048 chunk below the deepest is kept",
          .timeLimit(.minutes(10)), .enabled(if: enabled))
    func targetOneChunkBelowDeepestIsKept() async throws {
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
            #expect(kept.positions == [2_048, 4_096, 6_144], "4,096 is 2,048 below 6,144, past the 1,024 adjacency")
            #expect(store.stats().filesWritten == 3)
            print("[qwen35-retention-adjacent] prompt=\(tokens.count) hint=5120 positions=\(kept.positions) "
                + "tensorBytes=\(kept.bytes) bytesWritten=\(store.stats().bytesWritten) mtp=\(fixture.mtpActive)")
            await bridge.shutdown()
            await store.closeAndWait()
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    /// The company-leaves case the uniform-chunk rule lost: a short request
    /// is decoding when the 9k donor arrives, so the donor prefills in plain
    /// 512-token chunks; the short request is cancelled mid-prompt and the
    /// donor's remaining ranges are 2,048-token solo stripes. Capture is
    /// chunk-agnostic, so boundaries continue past the switch, the retired
    /// cap-change counter stays at zero, and the next turn restores the
    /// deepest boundary with the same text as its cold control.
    @Test("a donor whose company leaves mid-prompt keeps capturing across the chunk switch",
          .timeLimit(.minutes(10)), .enabled(if: enabled))
    func companyLeavesMidPromptKeepsCapturing() async throws {
        let fixture = try await Qwen35CheckpointRetentionFixture()
        do {
            let stripe = Qwen35CheckpointRetentionFixture.stripeTokens
            let donorTokens = fixture.prompts.donor
            let next = try fixture.continuation()
            let store = try fixture.makeStore()
            let bridge = try fixture.makeBridge(store: store, maxConcurrentRequests: 2)
            let trace = try await fixture.observeGeometry(bridge)
            // The companion must be decoding before the donor is admitted.
            let companionTokens = try fixture.companionPrompt()
            let companionSignal = EngineV2RequestUsageSignal()
            let companionRequest = ChatCompletionRequest(model: fixture.modelID,
                messages: [ChatMessage(role: "user", content: "pre-tokenized fixture")],
                temperature: 0, max_tokens: 3_000)
            let companionStream = await bridge.submitTokenized(promptTokens: companionTokens,
                request: companionRequest, requestId: "companion", cacheScope: "tenant-c",
                usageSignal: companionSignal)
            let companionDone = Task { () -> Int in
                var chunks = 0
                for await event in companionStream { if case .chunk = event { chunks += 1 } }
                return chunks
            }
            let companionStarted = ContinuousClock.now
            while true {
                let computed = try await fixture.computedTokens(bridge, promptLength: companionTokens.count)
                if let computed, computed > companionTokens.count { break }
                try #require(ContinuousClock.now - companionStarted < .seconds(60), "companion never started decoding")
                try await taskSleep(.milliseconds(20))
            }
            let donorTask = Task {
                try await run(fixture, bridge: bridge, tokens: donorTokens, scope: "tenant-a",
                    id: "company-leaves-donor", expectedMarker: Qwen35CheckpointRetentionFixture.releaseMarker,
                    donationDemand: .init(repeatedPrefixTokens: 5_120))
            }
            // Cancel the companion once the donor is well into its 512-chunk
            // prefill, leaving at least two full stripes to run solo.
            let donorStarted = ContinuousClock.now
            while true {
                let computed = try await fixture.computedTokens(bridge, promptLength: donorTokens.count) ?? 0
                if computed >= 3 * 1_024 { break }
                try #require(ContinuousClock.now - donorStarted < .seconds(120), "donor never reached 3,072 tokens")
                try await taskSleep(.milliseconds(10))
            }
            await bridge.cancel(requestId: "companion")
            let donor = try await donorTask.value
            let companionChunks = await companionDone.value
            #expect(donor.hitTokens == 0)
            #expect(companionChunks > 0)
            try await requireIdle(bridge)
            await store.waitForWritesForTesting()

            let records = trace.records(promptLength: donorTokens.count)
            let widths = records.map { $0.range.count }
            let caps = Set(records.map(\.cap))
            #expect(caps.contains(512) && caps.contains(stripe),
                    "the donor must have prefilled in plain chunks and then stripes: caps=\(caps) widths=\(widths)")
            #expect(!records.contains { $0.outcome == "disarm" }, "no prompt range disarmed: \(records.map(\.outcome))")
            let captured = records.filter { $0.outcome == "capture" }.map(\.range.upperBound)
            #expect(captured == records.map(\.range.upperBound).filter { $0 % PrefixCachePolicy.blockSize == 0 },
                    "every aligned range end is a boundary")
            let firstStripeEnd = records.first { $0.cap == stripe }?.range.upperBound ?? .max
            #expect(captured.contains { $0 > firstStripeEnd }, "boundaries continue past the chunk switch: \(captured)")
            #expect(store.stats().recurrentCaptureDisarmedPacked == 0,
                    "no donor range ran packed in this schedule")
            let kept = try fixture.positions(scope: "tenant-a", prefixOf: donorTokens)
            let deepest = try #require(captured.max())
            #expect(kept.positions == Self.expectedRetained(captured: captured, hint: 5_120),
                    "retained first (at the store floor), fork target at or below 5,120, deepest: \(kept.positions)")
            let chunkSizes = try fixture.persistedManifests()
                .filter { $0.cacheSalt == "tenant-a" }.sorted { $0.position < $1.position }.map(\.chunkSize)
            print("[qwen35-company-leaves] prompt=\(donorTokens.count) widths=\(widths) captured=\(captured) "
                + "positions=\(kept.positions) tensorBytes=\(kept.bytes) chunkSizes=\(chunkSizes) "
                + "disarmed=\(store.stats().recurrentCaptureDisarmedPacked) filesWritten=\(store.stats().filesWritten) "
                + "mtp=\(fixture.mtpActive) companionChunks=\(companionChunks)")
            await bridge.shutdown()
            await store.closeAndWait()

            // The next turn restores the deepest boundary, and answers as cold.
            try #require(next.shared >= deepest)
            let nextStore = try fixture.makeStore()
            let nextBridge = try fixture.makeBridge(store: nextStore)
            let nextHint = next.shared / PrefixCachePolicy.blockSize * PrefixCachePolicy.blockSize
            let turn = try await run(fixture, bridge: nextBridge, tokens: next.tokens, scope: "tenant-a",
                id: "company-leaves-next", expectedMarker: Qwen35CheckpointRetentionFixture.backupMarker,
                donationDemand: .init(repeatedPrefixTokens: nextHint))
            #expect(turn.hitTokens == deepest, "the next turn restores the deepest boundary \(deepest)")
            try await requireIdle(nextBridge)
            await nextBridge.shutdown()
            await nextStore.closeAndWait()
            let coldBridge = try fixture.makeBridge(store: nil)
            let cold = try await run(fixture, bridge: coldBridge, tokens: next.tokens, scope: "tenant-a",
                id: "company-leaves-cold", expectedMarker: Qwen35CheckpointRetentionFixture.backupMarker)
            try await requireIdle(coldBridge)
            #expect(turn.text == cold.text, "a restore across a mixed partition must answer exactly as its cold control")
            print("[qwen35-company-leaves] nextPrompt=\(next.tokens.count) hit=\(turn.hitTokens) deepest=\(deepest) "
                + "sameText=\(turn.text == cold.text) warmTTFT=\(turn.ttft) offTTFT=\(cold.ttft) "
                + "bytesRead=\(nextStore.stats().bytesRead)")
            await coldBridge.shutdown()
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    /// MoE sanity run (`DARKBLOOM_LIVE_MLX_QWEN36_MOE_CHECKPOINT=1`, 20 GB of
    /// weights). On the MoE the state at a boundary depends on the chunk
    /// partition below it, and so does a cold run's output, so exactness is
    /// judged against a cold control that used the same partition: a solo
    /// donor and a solo next turn both run 2,048 stripes over the shared
    /// prefix. A company-leaves donor then shows the geometry claim alone:
    /// boundaries continue past the chunk switch and its deepest restores.
    @Test("MoE: a solo donor's deepest boundary restores to its matching cold run; a mixed donor keeps capturing",
          .timeLimit(.minutes(15)),
          .enabled(if: enabled && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_QWEN36_MOE_CHECKPOINT"] == "1"))
    func moePartitionSanity() async throws {
        let fixture = try await Qwen35CheckpointRetentionFixture(
            modelID: Qwen35CheckpointRetentionFixture.moeModelID, memoryBudgetBytes: 64 << 30)
        do {
            let donorTokens = fixture.prompts.donor
            let next = try fixture.continuation()
            let deepest = donorTokens.count / Qwen35CheckpointRetentionFixture.stripeTokens
                * Qwen35CheckpointRetentionFixture.stripeTokens
            // Solo donor, solo restore: matching partitions below the boundary.
            let store = try fixture.makeStore()
            let bridge = try fixture.makeBridge(store: store)
            let donor = try await run(fixture, bridge: bridge, tokens: donorTokens, scope: "tenant-a",
                id: "moe-donor", expectedMarker: Qwen35CheckpointRetentionFixture.releaseMarker,
                donationDemand: .init(repeatedPrefixTokens: 5_120))
            #expect(donor.hitTokens == 0)
            try await requireIdle(bridge)
            await store.waitForWritesForTesting()
            let kept = try fixture.positions(scope: "tenant-a", prefixOf: donorTokens)
            #expect(kept.positions == [2_048, 4_096, deepest])
            print("[qwen36-moe] modelHash=\(fixture.modelHash) prompt=\(donorTokens.count) positions=\(kept.positions) "
                + "tensorBytes=\(kept.bytes) bytesWritten=\(store.stats().bytesWritten) mtp=\(fixture.mtpActive) "
                + "donorTTFT=\(donor.ttft)")
            await bridge.shutdown()
            await store.closeAndWait()
            let nextStore = try fixture.makeStore()
            let nextBridge = try fixture.makeBridge(store: nextStore)
            let nextHint = next.shared / PrefixCachePolicy.blockSize * PrefixCachePolicy.blockSize
            let turn = try await run(fixture, bridge: nextBridge, tokens: next.tokens, scope: "tenant-a",
                id: "moe-next", expectedMarker: Qwen35CheckpointRetentionFixture.backupMarker,
                donationDemand: .init(repeatedPrefixTokens: nextHint))
            #expect(turn.hitTokens == deepest)
            try await requireIdle(nextBridge)
            await nextBridge.shutdown()
            await nextStore.closeAndWait()
            let coldBridge = try fixture.makeBridge(store: nil)
            let cold = try await run(fixture, bridge: coldBridge, tokens: next.tokens, scope: "tenant-a",
                id: "moe-cold", expectedMarker: Qwen35CheckpointRetentionFixture.backupMarker)
            try await requireIdle(coldBridge)
            #expect(turn.text == cold.text, "solo donor, solo restore: the same partition below \(deepest)")
            print("[qwen36-moe] nextPrompt=\(next.tokens.count) hit=\(turn.hitTokens) deepest=\(deepest) "
                + "sameText=\(turn.text == cold.text) warmTTFT=\(turn.ttft) offTTFT=\(cold.ttft)")
            await coldBridge.shutdown()

            // Company leaves mid-prompt: the geometry claim on the MoE.
            let mixedStore = try fixture.makeStore()
            let mixedBridge = try fixture.makeBridge(store: mixedStore, maxConcurrentRequests: 2)
            let trace = try await fixture.observeGeometry(mixedBridge)
            let companionTokens = try fixture.companionPrompt()
            let companionRequest = ChatCompletionRequest(model: fixture.modelID,
                messages: [ChatMessage(role: "user", content: "pre-tokenized fixture")],
                temperature: 0, max_tokens: 3_000)
            let companionStream = await mixedBridge.submitTokenized(promptTokens: companionTokens,
                request: companionRequest, requestId: "moe-companion", cacheScope: "tenant-c",
                usageSignal: EngineV2RequestUsageSignal())
            let companionDone = Task { for await _ in companionStream {} }
            let companionStarted = ContinuousClock.now
            while true {
                let computed = try await fixture.computedTokens(mixedBridge, promptLength: companionTokens.count)
                if let computed, computed > companionTokens.count { break }
                try #require(ContinuousClock.now - companionStarted < .seconds(120), "companion never started decoding")
                try await taskSleep(.milliseconds(20))
            }
            let mixedTask = Task {
                try await run(fixture, bridge: mixedBridge, tokens: donorTokens, scope: "tenant-b",
                    id: "moe-mixed-donor", expectedMarker: Qwen35CheckpointRetentionFixture.releaseMarker,
                    donationDemand: .init(repeatedPrefixTokens: 5_120))
            }
            let mixedStarted = ContinuousClock.now
            while true {
                let computed = try await fixture.computedTokens(mixedBridge, promptLength: donorTokens.count) ?? 0
                if computed >= 3 * 1_024 { break }
                try #require(ContinuousClock.now - mixedStarted < .seconds(180), "mixed donor never reached 3,072 tokens")
                try await taskSleep(.milliseconds(10))
            }
            await mixedBridge.cancel(requestId: "moe-companion")
            let mixed = try await mixedTask.value
            await companionDone.value
            try await requireIdle(mixedBridge)
            await mixedStore.waitForWritesForTesting()
            let records = trace.records(promptLength: donorTokens.count)
            let widths = records.map { $0.range.count }
            let captured = records.filter { $0.outcome == "capture" }.map(\.range.upperBound)
            let firstStripeEnd = records.first { $0.cap == Qwen35CheckpointRetentionFixture.stripeTokens }?
                .range.upperBound ?? .max
            #expect(Set(records.map(\.cap)).contains(512), "the mixed donor prefilled in plain chunks under company")
            #expect(!records.contains { $0.outcome == "disarm" })
            #expect(captured.contains { $0 > firstStripeEnd }, "boundaries continue past the switch: \(captured)")
            #expect(mixedStore.stats().recurrentCaptureDisarmedPacked == 0)
            let mixedKept = try fixture.positions(scope: "tenant-b", prefixOf: donorTokens)
            let mixedDeepest = try #require(captured.max())
            #expect(mixedKept.positions == Self.expectedRetained(captured: captured, hint: 5_120),
                    "retained first (at the store floor), fork target at or below 5,120, deepest: \(mixedKept.positions)")
            print("[qwen36-moe-mixed] widths=\(widths) captured=\(captured) positions=\(mixedKept.positions) "
                + "tensorBytes=\(mixedKept.bytes) disarmed=\(mixedStore.stats().recurrentCaptureDisarmedPacked) "
                + "answer=\(mixed.answer.debugDescription)")
            await mixedBridge.shutdown()
            await mixedStore.closeAndWait()

            // The mixed-partition checkpoint must restore too: MoE state is
            // partition-dependent, so the dense mixed restore does not cover
            // this codec/adopter path. A fresh store rescans the files on
            // disk; the next turn restores the deepest mixed boundary and
            // answers with the expected marker.
            let mixedNext = try fixture.continuation()
            try #require(mixedNext.shared >= mixedDeepest)
            let mixedNextStore = try fixture.makeStore()
            let mixedNextBridge = try fixture.makeBridge(store: mixedNextStore)
            let mixedNextHint = mixedNext.shared / PrefixCachePolicy.blockSize * PrefixCachePolicy.blockSize
            let mixedTurn = try await run(fixture, bridge: mixedNextBridge, tokens: mixedNext.tokens, scope: "tenant-b",
                id: "moe-mixed-next", expectedMarker: Qwen35CheckpointRetentionFixture.backupMarker,
                donationDemand: .init(repeatedPrefixTokens: mixedNextHint))
            #expect(mixedTurn.hitTokens == mixedDeepest,
                    "the next turn restores the mixed donor's deepest boundary \(mixedDeepest)")
            try await requireIdle(mixedNextBridge)
            print("[qwen36-moe-mixed] nextPrompt=\(mixedNext.tokens.count) hit=\(mixedTurn.hitTokens) "
                + "deepest=\(mixedDeepest) warmTTFT=\(mixedTurn.ttft) answer=\(mixedTurn.answer.debugDescription)")
            await mixedNextBridge.shutdown()
            await mixedNextStore.closeAndWait()
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

    /// The positions a donor retains, derived from what it captured: the
    /// first boundary at or above the store's effective-token floor, the
    /// deepest captured boundary at or below the fork hint, and the deepest
    /// captured boundary; ascending, without duplicates.
    private static func expectedRetained(captured: [Int], hint: Int) -> [Int] {
        var expected = Set<Int>()
        if let first = captured.filter({ $0 >= SSDPrefixCachePolicy.defaultMinEffectiveTokens }).min() {
            expected.insert(first)
        }
        if let target = captured.filter({ $0 <= hint && $0 >= SSDPrefixCachePolicy.defaultMinEffectiveTokens }).max() {
            expected.insert(target)
        }
        if let deepest = captured.max() { expected.insert(deepest) }
        return expected.sorted()
    }

    private func run(_ fixture: Qwen35CheckpointRetentionFixture, bridge: EngineV2Bridge,
                     tokens: [Int], scope: String, id: String, expectedMarker: String,
                     donationDemand: SSDCheckpointDonationDemand? = nil) async throws -> Output {
        let signal = EngineV2RequestUsageSignal()
        let request = ChatCompletionRequest(model: fixture.modelID,
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
