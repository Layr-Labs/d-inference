import Foundation
import MLX
@_spi(Benchmarking) import MLXLMCommon
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

/// The Qwen 3.5/3.6 builds' default request (temperature 1, top-p 0.95, top-k 20 and the
/// card's presence penalty 1.5, here with a seed) cannot speculate. On real weights with the
/// production paged assembly, the inline MTP head and the encrypted complete-checkpoint store,
/// such a request must donate its prompt's checkpoints, answer exactly as with the cache off,
/// and let the same request, its next turn, and a speculating request restore them and answer
/// exactly as their cold runs (tokens through the text, and every logprob bit). Prints
/// time to first token and peak MLX memory per run for the GPU validation report. Run with
/// `DARKBLOOM_LIVE_MLX_TESTS=1 DARKBLOOM_LIVE_MLX_QWEN35_CARD_DONATION=1`; the dense run reads
/// `DARKBLOOM_LIVE_MLX_QWEN_RETENTION_MODEL`, the MoE run `DARKBLOOM_LIVE_MLX_QWEN_MOE_MODEL`.
@Suite("Qwen3.5 card-default checkpoint donation (live)", .serialized)
struct Qwen35CardDefaultDonationLiveTests {
    private static let enabled = LiveInferenceFixtures.liveTestsEnabled
        && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_QWEN35_CARD_DONATION"] == "1"
    static let maxTokens = Int(ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_QWEN35_CARD_TOKENS"] ?? "") ?? 256

    enum Target: String, CaseIterable, CustomTestStringConvertible {
        case dense, moe
        var testDescription: String { rawValue }
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
        var failure: String?
        for await event in stream {
            switch event {
            case .chunk(let text):
                if first == nil && !text.isEmpty { first = .now }
                output.text += text
            case .logprobs(let entries):
                for entry in entries {
                    output.logprobBits.append(entry.logprob.bitPattern)
                    output.logprobBits += entry.topLogprobs.map(\.logprob.bitPattern)
                }
            case .info(_, let completion, _, let reason):
                output.finish = reason
                output.completionTokens = completion
            case .error(let message): failure = message
            case .terminal(_, let message, _, _): failure = message
            }
        }
        try #require(failure == nil, "request \(id) failed: \(failure ?? "")")
        try await requireQwen35CheckpointIdle(bridge)
        let run = Run(output: output, hit: signal.prefixCacheHitTokens ?? 0,
                      ttft: (first ?? .now) - started, peakBytes: MLX.Memory.peakMemory)
        print("[qwen35-card-donation] id=\(id) hit=\(run.hit) ttft=\(run.ttft) peakBytes=\(run.peakBytes) "
            + "completion=\(output.completionTokens) finish=\(output.finish ?? "nil") "
            + "logprobs=\(output.logprobBits.count)")
        return run
    }

    @Test("card-default requests donate, and every restorer answers as its cold run",
          .timeLimit(.minutes(30)), .enabled(if: enabled), arguments: Target.allCases)
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
}
