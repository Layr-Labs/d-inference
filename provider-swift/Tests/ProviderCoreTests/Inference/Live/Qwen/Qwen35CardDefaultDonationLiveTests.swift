import Foundation
import MLX
@_spi(Benchmarking) import MLXLMCommon
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

/// A Qwen 3.5/3.6 request with the card's values (temperature 1, top-p 0.95, top-k 20 and the
/// presence penalty 1.5: the 35B builds' default; sent explicitly here, with a seed) cannot
/// speculate. On real weights with the
/// production paged assembly, the inline MTP head and the encrypted complete-checkpoint store,
/// such a request must donate its prompt's checkpoints, answer exactly as with the cache off,
/// and let the same request, its next turn, and a speculating request restore them and answer
/// exactly as their cold runs (tokens through the text, and every logprob bit). Prints
/// time to first token and peak MLX memory per run for the GPU validation report. Run with
/// `DARKBLOOM_LIVE_MLX_TESTS=1 DARKBLOOM_LIVE_MLX_QWEN35_CARD_DONATION=1`; the dense run reads
/// `DARKBLOOM_LIVE_MLX_QWEN_RETENTION_MODEL`, the MoE run `DARKBLOOM_LIVE_MLX_QWEN_MOE_MODEL`;
/// `DARKBLOOM_LIVE_MLX_QWEN35_CARD_TARGETS=dense` or `=moe` runs one of them.
@Suite("Qwen3.5 card-default checkpoint donation (live)", .serialized)
struct Qwen35CardDefaultDonationLiveTests {
    private static let enabled = LiveInferenceFixtures.liveTestsEnabled
        && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_QWEN35_CARD_DONATION"] == "1"
    static let maxTokens = Int(ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_QWEN35_CARD_TOKENS"] ?? "") ?? 256

    enum Target: String, CaseIterable, CustomTestStringConvertible {
        case dense, moe
        var testDescription: String { rawValue }
        static var selected: [Target] {
            let names = ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_QWEN35_CARD_TARGETS"]?
                .split(separator: ",").map(String.init)
            return allCases.filter { names?.contains($0.rawValue) ?? true }
        }
        var modelID: String {
            self == .dense ? Qwen35CheckpointRetentionFixture.modelID : Qwen35CheckpointRetentionFixture.moeModelID
        }
        /// The MoE build's slot budget, as `Qwen35CheckpointRetentionLiveTests` gives it.
        var memoryBudgetBytes: Int {
            self == .dense ? Qwen35CheckpointRetentionFixture.denseBudgetBytes : 64 << 30
        }
    }

    /// The card's request, alone or with what a client adds to it.
    enum Shape: String, CaseIterable {
        case card, cardStop, cardLogprobs
    }

    struct Output: Equatable {
        var text = ""
        var logprobBits: [UInt32] = []
        var finish: String?
        var completionTokens = 0
        static func == (a: Output, b: Output) -> Bool {
            a.text == b.text && a.logprobBits == b.logprobBits && a.finish == b.finish
                && a.completionTokens == b.completionTokens
        }
    }

    struct Run {
        var output: Output
        var hit: Int
        var ttft: Duration
        var peakBytes: Int
        /// From the last streamed chunk to the terminal: what a client waits after the answer,
        /// including a donor's synchronous checkpoint publication.
        var tail: Duration
    }

    static func card(_ fixture: Qwen35CheckpointRetentionFixture, _ shape: Shape, presencePenalty: Float = 1.5)
        -> ChatCompletionRequest
    {
        ChatCompletionRequest(
            model: fixture.modelID, messages: [ChatMessage(role: "user", content: "pre-tokenized fixture")],
            temperature: 1, top_p: 0.95, top_k: 20, max_tokens: maxTokens,
            presence_penalty: presencePenalty,
            stop: shape == .cardStop ? .single("§§never-matches§§") : nil, seed: 1_234,
            logprobs: shape == .cardLogprobs ? true : nil, top_logprobs: shape == .cardLogprobs ? 5 : nil)
    }

    static func run(
        _ bridge: EngineV2Bridge, tokens: [Int], request: ChatCompletionRequest, id: String
    ) async throws -> Run {
        let signal = EngineV2RequestUsageSignal()
        MLX.Memory.clearCache()
        MLX.Memory.peakMemory = 0
        let started = ContinuousClock.now
        let stream = await bridge.submitTokenized(
            promptTokens: tokens, request: request, requestId: id, cacheScope: "tenant-card",
            usageSignal: signal)
        var output = Output()
        var first: ContinuousClock.Instant?
        var last: ContinuousClock.Instant?
        var terminal: ContinuousClock.Instant?
        var failure: String?
        for await event in stream {
            switch event {
            case .chunk(let text):
                if first == nil && !text.isEmpty { first = .now }
                if !text.isEmpty { last = .now }
                output.text += text
            case .logprobs(let entries):
                for entry in entries {
                    output.logprobBits.append(entry.logprob.bitPattern)
                    output.logprobBits += entry.topLogprobs.map(\.logprob.bitPattern)
                }
            case .info(_, let completion, _, let reason):
                terminal = .now
                output.finish = reason
                output.completionTokens = completion
            case .error(let message): failure = message
            case .terminal(_, let message, _, _): failure = message
            }
        }
        try #require(failure == nil, "request \(id) failed: \(failure ?? "")")
        try await requireQwen35CheckpointIdle(bridge)
        let run = Run(output: output, hit: signal.prefixCacheHitTokens ?? 0,
                      ttft: (first ?? .now) - started, peakBytes: MLX.Memory.peakMemory,
                      tail: (terminal ?? .now) - (last ?? started))
        print("[qwen35-card-donation] id=\(id) prompt=\(tokens.count) hit=\(run.hit) ttft=\(run.ttft) tail=\(run.tail) "
            + "peakBytes=\(run.peakBytes) "
            + "completion=\(output.completionTokens) finish=\(output.finish ?? "nil") "
            + "logprobs=\(output.logprobBits.count)")
        return run
    }

    @Test("card-default requests donate, and every restorer answers as its cold run",
          .timeLimit(.minutes(45)), .enabled(if: enabled), arguments: Target.selected)
    func cardDefaultRequestsDonateAndRestoreExactly(_ target: Target) async throws {
        let fixture = try await Qwen35CheckpointRetentionFixture(
            modelID: target.modelID, memoryBudgetBytes: target.memoryBudgetBytes)
        do {
            try #require(fixture.mtpActive, "the artifact must load its embedded MTP head")
            let donorTokens = fixture.prompts.donor
            let next = try fixture.continuation()
            let stripe = Qwen35CheckpointRetentionFixture.stripeTokens

            for shape in Shape.allCases {
                let request = Self.card(fixture, shape)
                let coldBridge = try fixture.makeBridge(store: nil)
                let cold = try await Self.run(coldBridge, tokens: donorTokens, request: request, id: "cold-\(shape)")
                let coldNext = try await Self.run(coldBridge, tokens: next.tokens, request: request,
                                                  id: "cold-next-\(shape)")
                await coldBridge.shutdown()

                let store = try fixture.makeStore()
                let donorBridge = try fixture.makeBridge(store: store)
                let donor = try await Self.run(donorBridge, tokens: donorTokens, request: request,
                                               id: "donor-\(shape)")
                await store.waitForWritesForTesting()
                let kept = try fixture.positions(scope: "tenant-card", prefixOf: donorTokens)
                #expect(donor.output == cold.output, "\(shape): capture does not change the answer")
                #expect(!kept.positions.isEmpty, "\(shape): the card request donates")
                let deepest = kept.positions.max() ?? 0
                #expect(deepest >= donorTokens.count / stripe * stripe - stripe,
                        "\(shape): the deepest donated chunk end is near the prompt end")
                print("[qwen35-card-donation] shape=\(shape) prompt=\(donorTokens.count) positions=\(kept.positions) "
                    + "tensorBytes=\(kept.bytes) donorPeak=\(donor.peakBytes) coldPeak=\(cold.peakBytes) "
                    + "donorTTFT=\(donor.ttft) coldTTFT=\(cold.ttft)")
                await donorBridge.shutdown()
                await store.closeAndWait()

                let warmStore = try fixture.makeStore()
                let warmBridge = try fixture.makeBridge(store: warmStore)
                let warm = try await Self.run(warmBridge, tokens: donorTokens, request: request, id: "warm-\(shape)")
                #expect(warm.hit == deepest, "\(shape): the same request restores the deepest chunk end")
                #expect(warm.output == cold.output, "\(shape): a restored request answers as its cold run")
                let turn = try await Self.run(warmBridge, tokens: next.tokens, request: request,
                                              id: "next-\(shape)")
                #expect(turn.hit == deepest, "\(shape): the next turn restores the donor's deepest")
                #expect(turn.output == coldNext.output, "\(shape): the next turn answers as its cold run")
                print("[qwen35-card-donation] shape=\(shape) warmTTFT=\(warm.ttft) nextHit=\(turn.hit) "
                    + "nextTTFT=\(turn.ttft) coldNextTTFT=\(coldNext.ttft) sameNext=\(turn.output == coldNext.output)")
                await warmBridge.shutdown()
                await warmStore.closeAndWait()
                try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
                    .forEach { try FileManager.default.removeItem(at: $0) }
            }

            try await Self.extensionTurns(fixture)
            try await Self.longPrompt(fixture)

            // A speculating request (penalty 0) restores a card request's checkpoint. A fixed
            // depth makes its output deterministic run to run, under either acceptance rule.
            let store = try fixture.makeStore()
            let donorBridge = try fixture.makeBridge(store: store)
            _ = try await Self.run(donorBridge, tokens: donorTokens, request: Self.card(fixture, .card),
                                   id: "donor-for-speculation")
            await store.waitForWritesForTesting()
            let deepest = try fixture.positions(scope: "tenant-card", prefixOf: donorTokens).positions.max() ?? 0
            await donorBridge.shutdown()
            await store.closeAndWait()
            for acceptance in [CBv2MTPAcceptance.exact, .typical(delta: CBv2MTPAcceptance.defaultTypicalDelta)] {
                let config = CBv2MTPConfig(
                    enabled: true, maxDraftTokens: 2, fixedDraftTokens: 2, verificationMode: .rectangular,
                    acceptance: acceptance)
                let request = Self.card(fixture, .card, presencePenalty: 0)
                let coldBridge = try fixture.makeBridge(store: nil, mtpConfig: config)
                let cold = try await Self.run(coldBridge, tokens: donorTokens, request: request,
                                              id: "speculating-cold-\(acceptance.name)")
                let coldAgain = try await Self.run(coldBridge, tokens: donorTokens, request: request,
                                                   id: "speculating-cold-again-\(acceptance.name)")
                await coldBridge.shutdown()
                try #require(cold.output == coldAgain.output,
                             "\(acceptance.name): a fixed-depth speculating request is deterministic cold")
                let warmStore = try fixture.makeStore()
                let warmBridge = try fixture.makeBridge(store: warmStore, mtpConfig: config)
                let warm = try await Self.run(warmBridge, tokens: donorTokens, request: request,
                                              id: "speculating-warm-\(acceptance.name)")
                #expect(warm.hit == deepest, "\(acceptance.name)")
                #expect(warm.output == cold.output,
                        "\(acceptance.name): a speculating request restoring a card donor answers as its cold run")
                await warmBridge.shutdown()
                await warmStore.closeAndWait()
            }
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    /// Empties the fixture's cache root between independent sections.
    static func clearStore(_ fixture: Qwen35CheckpointRetentionFixture) throws {
        try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
            .forEach { try FileManager.default.removeItem(at: $0) }
    }

    static func records(count: Int, from start: Int) -> [String] {
        (start ..< start + count).map { n in
            "Record \(n): station \(n % 17) reported a routine inspection. The reservoir gauge was checked, the "
                + "inlet valve was serviced, and the next maintenance review remains proposed rather than approved."
        }
    }

    /// The multi-turn agent case: a card request that restored a checkpoint extends the head's
    /// history over its own prompt and donates the deeper chunk end; the turn after it restores
    /// that donation and answers exactly as its cold run.
    static func extensionTurns(_ fixture: Qwen35CheckpointRetentionFixture) async throws {
        typealias F = Qwen35CheckpointRetentionFixture
        let request = Self.card(fixture, .card)
        let donorTokens = fixture.prompts.donor
        let stripe = F.stripeTokens
        let opening = fixture.prompts.records.joined(separator: "\n") + "\n" + F.releaseQuestion + F.instruction
        func turns(_ added: Int) throws -> (second: [Int], third: [Int]) {
            let more = Self.records(count: added, from: 1_000).joined(separator: "\n") + "\n"
                + F.backupQuestion + F.instruction
            let second: [[String: String]] = [
                ["role": "user", "content": opening], ["role": "assistant", "content": F.releaseMarker],
                ["role": "user", "content": more],
            ]
            let third = second + [
                ["role": "assistant", "content": F.backupMarker],
                ["role": "user", "content": "Repeat both markers, the release marker first."],
            ]
            return (try fixture.tokenize(second), try fixture.tokenize(third))
        }
        // The second turn grows past the next chunk end by a margin.
        var added = 60
        var (second, third) = try turns(added)
        while second.count < donorTokens.count + stripe + 512 {
            added += 20
            (second, third) = try turns(added)
        }

        let coldBridge = try fixture.makeBridge(store: nil)
        let coldSecond = try await Self.run(coldBridge, tokens: second, request: request, id: "cold-second")
        let coldThird = try await Self.run(coldBridge, tokens: third, request: request, id: "cold-third")
        await coldBridge.shutdown()

        try Self.clearStore(fixture)
        let firstStore = try fixture.makeStore()
        let firstBridge = try fixture.makeBridge(store: firstStore)
        _ = try await Self.run(firstBridge, tokens: donorTokens, request: request, id: "ext-first")
        await firstStore.waitForWritesForTesting()
        let firstDeepest = try fixture.positions(scope: "tenant-card", prefixOf: donorTokens).positions.max() ?? 0
        try #require(firstDeepest > 0 && firstDeepest <= F.sharedPrefix(donorTokens, second))
        await firstBridge.shutdown()
        await firstStore.closeAndWait()

        let secondStore = try fixture.makeStore()
        let secondBridge = try fixture.makeBridge(store: secondStore)
        let warmSecond = try await Self.run(secondBridge, tokens: second, request: request, id: "ext-second")
        #expect(warmSecond.hit == firstDeepest, "the second turn restores the first turn's deepest")
        #expect(warmSecond.output == coldSecond.output, "the restored second turn answers as its cold run")
        await secondStore.waitForWritesForTesting()
        let secondDeepest = try fixture.positions(scope: "tenant-card", prefixOf: second).positions.max() ?? 0
        #expect(secondDeepest > firstDeepest, "the restored card request donates deeper: \(secondDeepest)")
        try #require(secondDeepest <= F.sharedPrefix(second, third))
        await secondBridge.shutdown()
        await secondStore.closeAndWait()

        let thirdStore = try fixture.makeStore()
        let thirdBridge = try fixture.makeBridge(store: thirdStore)
        let warmThird = try await Self.run(thirdBridge, tokens: third, request: request, id: "ext-third")
        #expect(warmThird.hit == secondDeepest, "the third turn restores the second turn's own donation")
        #expect(warmThird.output == coldThird.output, "a restore of a restored request's donation is exact")
        print("[qwen35-card-donation] extension second=\(second.count) third=\(third.count) "
            + "firstDeepest=\(firstDeepest) secondDeepest=\(secondDeepest) thirdHit=\(warmThird.hit) "
            + "secondTail=\(warmSecond.tail) coldSecondTail=\(coldSecond.tail) "
            + "thirdTTFT=\(warmThird.ttft) coldThirdTTFT=\(coldThird.ttft)")
        await thirdBridge.shutdown()
        await thirdStore.closeAndWait()
        try Self.clearStore(fixture)
    }

    /// A production-length agent prompt (about 32K tokens, under production's complete-checkpoint
    /// stage caps): cold, donor and warm answer alike. Prints the donor's peak MLX memory, its
    /// tail and the donated tensor bytes.
    static func longPrompt(_ fixture: Qwen35CheckpointRetentionFixture) async throws {
        typealias F = Qwen35CheckpointRetentionFixture
        let target = Int(ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_QWEN35_CARD_LONG_TOKENS"] ?? "")
            ?? 32_000
        let request = Self.card(fixture, .card)
        func tokenize(_ added: Int) throws -> [Int] {
            try fixture.tokenize([["role": "user", "content":
                (fixture.prompts.records + Self.records(count: added, from: fixture.prompts.records.count))
                    .joined(separator: "\n") + "\n" + F.releaseQuestion + F.instruction]])
        }
        let perRecord = max(1, fixture.prompts.donor.count / fixture.prompts.records.count)
        var added = max(0, (target - fixture.prompts.donor.count) / perRecord)
        var tokens = try tokenize(added)
        while tokens.count < target {
            added += 20
            tokens = try tokenize(added)
        }
        func productionStore() throws -> SSDHybridCheckpointStore {
            try fixture.makeStore(
                maxReadBytes: SSDPrefixCachePolicy.completeCheckpointMaxStageBytes(environment: [:]),
                maxStageMillis: SSDPrefixCachePolicy.completeCheckpointMaxStageMillis(environment: [:]))
        }

        let coldBridge = try fixture.makeBridge(store: nil)
        let cold = try await Self.run(coldBridge, tokens: tokens, request: request, id: "long-cold")
        await coldBridge.shutdown()

        try Self.clearStore(fixture)
        let store = try productionStore()
        let donorBridge = try fixture.makeBridge(store: store)
        let donor = try await Self.run(donorBridge, tokens: tokens, request: request, id: "long-donor")
        await store.waitForWritesForTesting()
        let kept = try fixture.positions(scope: "tenant-card", prefixOf: tokens)
        #expect(donor.output == cold.output, "a long card donor answers as its cold run")
        #expect((kept.positions.max() ?? 0) >= tokens.count / F.stripeTokens * F.stripeTokens - F.stripeTokens,
                "a long card request donates near its prompt end: \(kept.positions)")
        await donorBridge.shutdown()
        await store.closeAndWait()

        let warmStore = try productionStore()
        let warmBridge = try fixture.makeBridge(store: warmStore)
        let warm = try await Self.run(warmBridge, tokens: tokens, request: request, id: "long-warm")
        #expect(warm.hit == kept.positions.max() ?? 0, "the long prompt restores its deepest donation")
        #expect(warm.output == cold.output, "a restored long card request answers as its cold run")
        print("[qwen35-card-donation] long prompt=\(tokens.count) positions=\(kept.positions) "
            + "tensorBytes=\(kept.bytes) donorPeak=\(donor.peakBytes) coldPeak=\(cold.peakBytes) "
            + "donorTail=\(donor.tail) coldTail=\(cold.tail) warmTTFT=\(warm.ttft) coldTTFT=\(cold.ttft)")
        await warmBridge.shutdown()
        await warmStore.closeAndWait()
        try Self.clearStore(fixture)
    }

    /// Informational (P1-info): a card request decoding beside another card request's ~8K
    /// prompt, with the cache on (the prompt's steps become MTP steps) and off. Prints whether
    /// the decoder's output is the same; it does not fail on a difference.
    @Test("a card decode beside a card prompt, cache on and off (informational)",
          .timeLimit(.minutes(15)), .enabled(if: enabled), arguments: Target.selected)
    func decodeBesideCardPromptInfo(_ target: Target) async throws {
        let fixture = try await Qwen35CheckpointRetentionFixture(
            modelID: target.modelID, memoryBudgetBytes: target.memoryBudgetBytes)
        do {
            let request = Self.card(fixture, .cardLogprobs)
            let short = try fixture.tokenize([["role": "user", "content":
                "Write a long, detailed essay about the history of harbours, one paragraph per century."]])
            func together(_ store: SSDHybridCheckpointStore?) async throws -> Output {
                let bridge = try fixture.makeBridge(store: store, maxConcurrentRequests: 2)
                async let decoding = Self.run(bridge, tokens: short, request: request, id: "beside-decoding")
                try await Task.sleep(for: .milliseconds(300))
                _ = try await Self.run(bridge, tokens: fixture.prompts.donor, request: request, id: "beside-prompt")
                let output = try await decoding.output
                await bridge.shutdown()
                return output
            }
            let off = try await together(nil)
            try Self.clearStore(fixture)
            let on = try await together(try fixture.makeStore())
            print("[qwen35-card-donation] P1-info sameDecoder=\(on == off) "
                + "textEqual=\(on.text == off.text) logprobsEqual=\(on.logprobBits == off.logprobBits)")
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }
}
