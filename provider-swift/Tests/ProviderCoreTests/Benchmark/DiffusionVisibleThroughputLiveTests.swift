import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing
import XCTest

@_spi(Benchmarking) @testable import ProviderCore

/// Measurement only: a successful test does not claim the 500 visible-token/s
/// objective or all release gates passed. No shorter canvas or sampler override.
@Suite("DiffusionGemma finalized visible throughput", .serialized)
struct DiffusionVisibleThroughputLiveTests {
    private enum AccountingError: Error { case mismatchedText, hiddenReasoning, ambiguousVisibleRange, unalignedFraming }
    private func visible(_ sample: DiffusionGemmaBenchmarkIteration,
                         tokenizer: any Tokenizer) throws -> (text: String, tokens: Int, framing: Int) {
        let raw = tokenizer.decode(tokenIds: sample.tokenIDs, skipSpecialTokens: false)
        guard Data(raw.utf8) == Data(sample.text.utf8) else { throw AccountingError.mismatchedText }
        var splitter = DiffusionGemmaChannelSplitter()
        let pieces = splitter.parse(raw) + splitter.finish()
        let text = pieces.map(\.content).joined()
        guard pieces.compactMap(\.reasoningContent).joined().isEmpty else { throw AccountingError.hiddenReasoning }
        let rawBytes = Data(raw.utf8), textBytes = Data(text.utf8)
        guard !textBytes.isEmpty && rawBytes.suffix(textBytes.count) == textBytes else {
            throw AccountingError.ambiguousVisibleRange
        }
        let header = Data(rawBytes.dropLast(textBytes.count))
        let framing: Int
        if header.isEmpty { framing = 0 }
        else {
            guard let count = (1...min(64, sample.tokenIDs.count)).first(where: { count in
                Data(tokenizer.decode(tokenIds: Array(sample.tokenIDs.prefix(count)), skipSpecialTokens: false).utf8) == header
            }) else { throw AccountingError.unalignedFraming }
            framing = count
        }
        return (text, sample.tokenIDs.count - framing, framing)
    }

    private struct CountingTokenizer: Tokenizer {
        let tokens: [String]
        var bosToken: String? { nil }
        var eosToken: String? { nil }
        var unknownToken: String? { nil }
        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            Issue.record("Visible native counts must not retokenize display text")
            return []
        }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tokenIds.map { tokens[$0] }.joined() }
        func convertTokenToId(_ token: String) -> Int? { tokens.firstIndex(of: token) }
        func convertIdToToken(_ id: Int) -> String? { tokens.indices.contains(id) ? tokens[id] : nil }
        func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                               additionalContext: [String: any Sendable]?) throws -> [Int] { [] }
    }
    private func sample(_ tokenizer: CountingTokenizer, text: String? = nil) -> DiffusionGemmaBenchmarkIteration {
        let ids = Array(tokenizer.tokens.indices)
        return .init(tokenIDs: ids, text: text ?? tokenizer.decode(tokenIds: ids, skipSpecialTokens: false),
            usage: .init(promptTokens: 1, completionTokens: ids.count), totalMilliseconds: 1)
    }

    @Test(arguments: ["<|channel>thought", "<|channel>thought\n"])
    func originalVisibleCountsExcludeOnlyProvedHeaderTokens(_ header: String) throws {
        let tokenizer = CountingTokenizer(tokens: [header, "<channel|>", "Ocean ", "currents 🌊"])
        let result = try visible(sample(tokenizer), tokenizer: tokenizer)
        #expect(result.tokens == 2 && result.framing == 2 && result.text == "Ocean currents 🌊")
        let plain = CountingTokenizer(tokens: ["Ocean ", "currents 🌊"])
        #expect(try visible(sample(plain), tokenizer: plain).tokens == 2)
    }

    @Test func ambiguousCountsAndHiddenReasoningCannotQualifyThroughput() {
        for tokens in [["<|channel>thought\n", "private", "<channel|>", "Ocean"],
                       ["<|channel>thought<channel|>Ocean"]] {
            let tokenizer = CountingTokenizer(tokens: tokens)
            #expect(throws: AccountingError.self) { try visible(sample(tokenizer), tokenizer: tokenizer) }
        }
        let tokenizer = CountingTokenizer(tokens: ["Ocean"])
        #expect(throws: AccountingError.self) { try visible(sample(tokenizer, text: "different"), tokenizer: tokenizer) }
    }

    @Test func nonProtocolMarkerLookingTextRemainsVisibleData() throws {
        let tokenizer = CountingTokenizer(tokens: ["<|channel>thought", "private", "<channel|>", "Ocean"])
        let result = try visible(sample(tokenizer), tokenizer: tokenizer)
        #expect(result.tokens == 4 && result.framing == 0)
        #expect(result.text == "<|channel>thoughtprivate<channel|>Ocean")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_VISIBLE_BENCH_LIVE"] == "1"))
    func sustainedNativeOutputExcludesFramingAndIncludesFirstBlock() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_MODEL_DIR"]))
        _ = Bundle(for: DiffusionVisibleThroughputAnchor.self).bundleURL
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        let prompt = """
        Write an original, detailed educational article about ocean currents and climate for a curious university student.
        Explain wind-driven circulation, the Coriolis effect, gyres, upwelling, density and deep circulation, heat transport,
        ecological effects, and how scientists observe these systems. Use clear prose with eight numbered section headings.
        Aim for at least 1,800 words with useful explanations and concrete examples. Do not use tools or quotations.
        Begin the article directly and develop every section fully.
        """
        var reference: [Int]?
        for backend in ["contiguous", "paged"] {
            Memory.clearCache()
            let before = Memory.snapshot()
            Memory.peakMemory = 0
            let report = try await EngineV2Factory.runDiffusionGemmaBenchmark(
                modelID: "mlx-community/diffusiongemma-26B-A4B-it-4bit", directory: directory,
                prompt: prompt, iterations: 3, maxTokens: 2048, backend: backend)
            let after = Memory.snapshot()
            try #require(report.weightHash == "2ad9d4a10fe791e9e74a6475298c048e9da2d3df9e049eeb37a9d98055fcc2ce")
            try #require(report.iterations.count == 3)
            #expect(after.activeMemory <= before.activeMemory + (16 << 20))
            for (index, sample) in report.iterations.enumerated() {
                let output = try visible(sample, tokenizer: tokenizer)
                // A short EOS answer is not a sustained-throughput workload.
                try #require(output.tokens >= 1536 && output.text.utf8.count >= 4000)
                #expect(output.text.lowercased().contains("ocean"))
                #expect(!output.text.contains("<|channel>") && !output.text.contains("<channel|>"))
                #expect(sample.usage.timing.batchRowsMax == 1)
                try #require(sample.generationMilliseconds > 0 && sample.prefillMilliseconds > 0)
                if let reference { #expect(sample.tokenIDs == reference) } else { reference = sample.tokenIDs }
                let rate = Double(output.tokens) * 1000 / sample.generationMilliseconds
                var row: [String: Any] = [
                    "backend": report.backend, "iteration": index + 1,
                    "promptTokens": sample.usage.promptTokens, "outputLimit": 2048,
                    "rawCommittedTokensExcludingEOS": sample.tokenIDs.count,
                    "visibleCommittedTokens": output.tokens, "excludedInitialFramingTokens": output.framing,
                    "generationIncludingFirstBlockMilliseconds": sample.generationMilliseconds,
                    "visibleTokensPerSecond": rate, "meets500ThisSample": rate >= 500,
                    "firstCommittedMilliseconds": sample.firstCommittedMilliseconds,
                    "prefillMilliseconds": sample.prefillMilliseconds,
                    "loadIncludingIntegrityMilliseconds": report.loadMilliseconds,
                    "totalMilliseconds": sample.totalMilliseconds, "batchRowsMax": sample.usage.timing.batchRowsMax,
                    "weightHash": report.weightHash, "seed": 341, "temperature": 1,
                    "cacheEnabled": false, "reasoningEnabled": false, "samplerAndCanvasUnchanged": true,
                    "tokenSHA256": SHA256.hash(data: try JSONEncoder().encode(sample.tokenIDs)).map { String(format: "%02x", $0) }.joined(),
                    "visibleTextSHA256": SHA256.hash(data: Data(output.text.utf8)).map { String(format: "%02x", $0) }.joined(),
                    "mlxActiveAfterRetirementBytes": after.activeMemory, "mlxPeakIncludingLoadBytes": after.peakMemory,
                    "fullPerformanceGoalQualified": false,
                ]
                if index == 0 { row["syntheticWorkloadVisibleText"] = output.text }
                print("DIFFUSION_VISIBLE_BENCH " + String(decoding: try JSONSerialization.data(
                    withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
            }
        }
    }
}

private final class DiffusionVisibleThroughputAnchor: XCTestCase {}
