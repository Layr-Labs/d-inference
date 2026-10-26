import Foundation
import MLXLMCommon
import ProviderCoreFoundation
import Testing

@_spi(Benchmarking) @testable import ProviderCore

/// Opt-in real-model observation of complete-checkpoint reuse across one
/// growing conversation. Each turn appends public synthetic records to the
/// previous prompt and is served with the previous prompt as the coordinator's
/// repeated-prefix hint, as an agent loop's next turn would be. Per turn the
/// report records TTFT, restored tokens, the gap from the last token to the
/// terminal (which waits for checkpoint publication) and the checkpoint bytes
/// written. Every turn after the first must restore part of the previous one;
/// timings and bytes are otherwise observations.
@Suite("Complete-checkpoint conversation growth (live)", .serialized)
struct ModelCheckpointConversationLiveTests {
    private static let environment = ProcessInfo.processInfo.environment
    private static let enabled = environment["DARKBLOOM_CHECKPOINT_CONVERSATION_BENCHMARK"] == "1"
    /// First prompt, per-turn growth and turn count. The prompts outgrow the
    /// 1 GiB stage cap's depth, so the stage cap decides each restore.
    static let firstTurnTokens = 30_000
    static let turnGrowthTokens = 5_000
    static let turns = 6

    struct Sample: Codable, Sendable {
        let turn: Int
        let promptTokens: Int
        let sharedTokens: Int
        let stageDisposition: String
        let restoredTokens: Int
        let firstOutputSeconds: Double
        let lastOutputSeconds: Double
        let terminalSeconds: Double
        let filesWritten: Int
        let bytesWritten: Int
    }

    struct Report: Codable {
        let modelID: String
        let weightHash: String
        var runtime: ModelPrefixBenchmarkReport?
        var maximumStageMegabytes: Int?
        var samples: [Sample] = []
        var failure: String?

        func save(to path: String) throws {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        }
    }

    @Test("a growing conversation restores its previous turn; bytes written per turn are recorded",
          .timeLimit(.minutes(60)), .enabled(if: enabled))
    func conversationGrowth() async throws {
        let output = try #require(Self.environment["DARKBLOOM_CHECKPOINT_CONVERSATION_OUTPUT"])
        try #require(output.hasPrefix("/") && !FileManager.default.fileExists(atPath: output),
            "the report output must be a new absolute path")
        try #require(Self.environment["DARKBLOOM_PREFIX_EXCLUSIVE_GPU"] == "1",
            "the timings need exclusive GPU use, as ModelPrefixBenchmarkLiveTests does")
        let specification = try ModelPrefixBenchmarkSpecification.load()
        try #require(specification.resolvedLiveKVQuantization == "native"
            && specification.resolvedCheckpointQuantization == "native",
            "the conversation benchmark uses native live/storage; lossy profiles belong in ModelCheckpointStorageLiveTests")
        try #require(specification.modelType != "mimo_v2",
            "native-bound MiMo imports are outside the provider-staged staging contract")
        // Unset keeps the production default for this Mac's memory size.
        let stageMegabytes = try Self.environment["DARKBLOOM_CHECKPOINT_CONVERSATION_STAGE_MB"].map {
            try #require(Int($0), "the stage cap override must be whole megabytes")
        }
        let fixture = try await ModelPrefixBenchmarkFixture(specification, maximumStageMegabytes: stageMegabytes)
        var report = Report(modelID: specification.modelID, weightHash: specification.expectedWeightHash,
            maximumStageMegabytes: stageMegabytes)
        do {
            report.runtime = await fixture.makeReport(comparison: "checkpoint_conversation")
            var conversation = try Conversation(fixture: fixture)
            var previous: [Int] = []
            for turn in 0..<Self.turns {
                let tokens = try conversation.grow(to: Self.firstTurnTokens + turn * Self.turnGrowthTokens)
                let sample = try await Self.serve(fixture, turn: turn, tokens: tokens, previous: previous)
                report.samples.append(sample)
                try report.save(to: output)
                if turn > 0 && sample.restoredTokens == 0 {
                    report.failure = "turn \(turn) restored nothing of the previous turn"
                    try report.save(to: output)
                }
                #expect(turn == 0 || sample.restoredTokens > 0, "turn \(turn) restored nothing of the previous turn")
                previous = tokens
            }
        } catch {
            let failure = error
            report.failure = String(describing: failure)
            do { try await fixture.close() } catch { report.failure = "\(failure); teardown: \(error)" }
            try report.save(to: output)
            throw failure
        }
        do { try await fixture.close() } catch {
            report.failure = [report.failure, "teardown: \(error)"].compactMap { $0 }.joined(separator: "; ")
            try report.save(to: output)
            throw error
        }
    }

    /// One conversation scope; the hint is the prefix shared with the previous
    /// turn. TTFT starts before staging, matching the session's caller clock.
    private static func serve(_ fixture: ModelPrefixBenchmarkFixture, turn: Int, tokens: [Int],
                              previous: [Int]) async throws -> Sample {
        let shared = zip(previous, tokens).prefix(while: { $0.0 == $0.1 }).count
        var request = ModelPrefixBenchmarkFixture.benchmarkRequest(tokens: tokens, scope: "conversation",
            target: previous.isEmpty ? nil : shared, cacheEnabled: true,
            outputTokens: fixture.specification.outputTokens)
        request.id = CBv2RequestID(UInt64(2_000 + turn))
        let before = try #require(await fixture.session.cacheSnapshot().checkpoints)
        let started = ContinuousClock.now
        let submitted = try await fixture.session.submit(request)
        var first: ContinuousClock.Instant?
        var last: ContinuousClock.Instant?
        var outputCount = 0
        var finish: CBv2FinishReason?
        var finalUsage: CBv2Usage?
        for await event in submitted.events {
            switch event {
            case .delta(_, let newTokens, _):
                if !newTokens.isEmpty {
                    last = .now
                    if first == nil { first = last }
                }
                outputCount += newTokens.count
            case .finished(let reason, let usage):
                finish = reason
                finalUsage = usage
            }
        }
        let terminal = ContinuousClock.now
        let usage = try await ModelPrefixBenchmarkTerminal.completeSuccessfulRequest(
            finish: finish, usage: finalUsage, outputCount: outputCount,
            expectedOutputCount: fixture.specification.outputTokens) {
                await fixture.session.complete(receiptID: submitted.receiptID)
            }
        try await fixture.session.drainCheckpointWrites()
        let after = try #require(await fixture.session.cacheSnapshot().checkpoints)
        let sample = Sample(turn: turn, promptTokens: tokens.count, sharedTokens: shared,
            stageDisposition: submitted.stageDisposition,
            restoredTokens: usage.prefixCachePrefillTokensSaved,
            firstOutputSeconds: (try #require(first) - started) / .seconds(1),
            lastOutputSeconds: (try #require(last) - started) / .seconds(1),
            terminalSeconds: (terminal - started) / .seconds(1),
            filesWritten: after.filesWritten - before.filesWritten,
            bytesWritten: after.bytesWritten - before.bytesWritten)
        print("[checkpoint-conversation] turn=\(turn) prompt=\(tokens.count) restored=\(sample.restoredTokens) "
            + "ttft_s=\(String(format: "%.2f", sample.firstOutputSeconds)) "
            + "terminal_after_last_s=\(String(format: "%.2f", sample.terminalSeconds - sample.lastOutputSeconds)) "
            + "written_mb=\(sample.bytesWritten / 1_000_000)")
        return sample
    }

    /// Public synthetic records appended to one user message, so each turn's
    /// tokens extend the previous turn's up to its closing template.
    private struct Conversation {
        let fixture: ModelPrefixBenchmarkFixture
        var text = "This is a synthetic public test. Reply with one word.\n"
        var records = 0

        init(fixture: ModelPrefixBenchmarkFixture) throws { self.fixture = fixture }

        mutating func grow(to minimum: Int) throws -> [Int] {
            while true {
                let tokens = try tokenize(text)
                if tokens.count >= minimum { return tokens }
                for _ in 0..<20 {
                    text += "Record \(records): station \(records % 17) checked the inlet valve, reconciled the "
                        + "pallet count, and scheduled a routine inspection.\n"
                    records += 1
                }
                try #require(records <= 40_000, "public prompt construction exceeded its bounded record count")
            }
        }

        private func tokenize(_ text: String) throws -> [Int] {
            let body = try JSONSerialization.data(withJSONObject: [
                "model": fixture.specification.openRouterID,
                "messages": [["role": "user", "content": text]],
                "temperature": 0, "max_tokens": fixture.specification.outputTokens,
                "chat_template_kwargs": ["enable_thinking": false],
            ])
            return try EngineV2Factory.benchmarkPrompt(body: body, tokenizer: fixture.tokenizer.inner,
                modelType: fixture.specification.modelType,
                defaultDate: #require(PromptRenderDate("2026-10-09"))).tokens
        }
    }
}
