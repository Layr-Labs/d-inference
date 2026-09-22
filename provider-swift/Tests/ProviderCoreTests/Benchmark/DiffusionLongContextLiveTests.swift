import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing
import XCTest

@_spi(Benchmarking) @testable import ProviderCore

/// One context per guarded process. A short known-answer completion qualifies
/// long prefill/state and retirement, not sustained generation throughput.
@Suite("DiffusionGemma long-context native provider", .serialized)
struct DiffusionLongContextLiveTests {
    private static let modelID = "mlx-community/diffusiongemma-26B-A4B-it-4bit"
    private static let selectedHash = "2ad9d4a10fe791e9e74a6475298c048e9da2d3df9e049eeb37a9d98055fcc2ce"

    private func prompt(target: Int, tokenizer: any Tokenizer) throws -> (String, Int) {
        let records = (0..<(target / 8 + 64)).map { index in
            "Record \(index): Cache pages belong to their request. Preserve positions, precision and ordering when processing this document."
        }
        func render(_ count: Int) throws -> (String, Int) {
            let text = "The document marker is ORCHID.\n" + records.prefix(count).joined(separator: "\n")
                + "\nWhat is the document marker? Reply with its single word only."
            let body: [String: Any] = [
                "model": Self.modelID, "messages": [["role": "user", "content": text]],
                "temperature": 1, "max_tokens": 64, "seed": 341, "reasoning": ["enabled": false],
            ]
            let tokens = try ProviderPromptContractPipeline.tokenizeProviderBody(
                JSONSerialization.data(withJSONObject: body), tokenizer: tokenizer,
                modelType: "diffusion_gemma")
            return (text, tokens.count)
        }
        var lower = 0, upper = records.count
        try #require(try render(upper).1 >= target)
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if try render(middle).1 < target { lower = middle + 1 } else { upper = middle }
        }
        let result = try render(lower)
        try #require(result.1 >= target && result.1 < target + 64)
        return result
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_LONG_CONTEXT_LIVE"] == "1"))
    func longPrefillMatchesAcrossStorageAndReleasesOwners() async throws {
        let environment = ProcessInfo.processInfo.environment
        let target = try #require(Int(environment["DARKBLOOM_DIFFUSION_CONTEXT_TOKENS"] ?? "4096"))
        try #require([1024, 4096, 10240, 20480, 51200, 81920, 131072, 253952, 262016].contains(target))
        let directory = URL(fileURLWithPath: try #require(environment["DARKBLOOM_DIFFUSION_MODEL_DIR"]))
        _ = Bundle(for: DiffusionLongContextBundleAnchor.self).bundleURL
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        let (text, expectedPromptTokens) = try prompt(target: target, tokenizer: tokenizer)
        let config = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as? [String: Any])
        let textConfig = try #require(config["text_config"] as? [String: Any])
        let nativeContext = try #require(textConfig["max_position_embeddings"] as? Int)
        try #require(nativeContext == 262144)
        // Context capacity is prompt plus reserved output, not input alone.
        // Preserve the ordinary known-answer prompt and reserve exactly the
        // remaining native budget for the boundary cell; do not slice framing.
        let outputLimit = target == 262016 ? nativeContext - expectedPromptTokens : 64
        try #require(outputLimit > 0 && outputLimit <= 128)
        var baseline: DiffusionGemmaBenchmarkIteration?
        for backend in ["contiguous", "paged"] {
            Memory.clearCache()
            let before = Memory.snapshot()
            Memory.peakMemory = 0
            print("DIFFUSION_LONG_CONTEXT_BEGIN backend=\(backend) promptTokens=\(expectedPromptTokens)")
            let report = try await EngineV2Factory.runDiffusionGemmaBenchmark(
                modelID: Self.modelID, directory: directory, prompt: text,
                iterations: 2, maxTokens: outputLimit, backend: backend)
            let after = Memory.snapshot()
            let limits = try #require(MLXMemoryGuard.configuredLimitsSnapshot(),
                "Ordinary native benchmarks must install the same allocator guard as serving")
            #expect(Memory.cacheLimit == limits.cacheLimitBytes)
            #expect(Memory.memoryLimit == limits.memoryLimitBytes)
            try #require(report.weightHash == Self.selectedHash)
            try #require(report.iterations.count == 2)
            // The report holds only host values. No loaded model, KV pool or
            // request tensor should survive the benchmark owner's retirement.
            #expect(after.activeMemory <= before.activeMemory + (16 << 20))
            for (index, sample) in report.iterations.enumerated() {
                #expect(sample.usage.promptTokens == expectedPromptTokens)
                #expect(sample.text.contains("ORCHID"), "Retain the literal known-answer quality oracle")
                #expect(sample.usage.completionTokens > 0 && sample.usage.completionTokens <= outputLimit)
                if target == 262016 {
                    #expect(sample.usage.promptTokens + outputLimit == nativeContext)
                }
                #expect(sample.prefillMilliseconds > 0 && sample.firstCommittedMilliseconds > 0)
                #expect(sample.usage.timing.batchRowsMax == 1)
                if let reference = baseline {
                    #expect(sample.tokenIDs == reference.tokenIDs)
                    #expect(sample.text == reference.text)
                    #expect(sample.usage.completionTokens == reference.usage.completionTokens)
                } else { baseline = sample }
                let record: [String: Any] = [
                    "backend": report.backend, "iteration": index + 1,
                    "promptTokens": sample.usage.promptTokens,
                    "requestedOutputTokens": outputLimit,
                    "nativeContextTokens": nativeContext,
                    "totalReservedTokenBudget": sample.usage.promptTokens + outputLimit,
                    "promptSHA256": SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
                    "weightHash": report.weightHash,
                    "loadIncludingIntegrityMilliseconds": report.loadMilliseconds,
                    "prefillMilliseconds": sample.prefillMilliseconds,
                    "prefillTokensPerSecond": Double(sample.usage.promptTokens) * 1000 / sample.prefillMilliseconds,
                    "firstCommittedMilliseconds": sample.firstCommittedMilliseconds,
                    "generationIncludingFirstBlockMilliseconds": sample.generationMilliseconds,
                    "committedTokensExcludingEOS": sample.tokenIDs.count,
                    "completionTokensIncludingEOS": sample.usage.completionTokens,
                    "committedTokenSHA256": SHA256.hash(data: try JSONEncoder().encode(sample.tokenIDs))
                        .map { String(format: "%02x", $0) }.joined(),
                    "mlxActiveBeforeLoadBytes": before.activeMemory,
                    "mlxActiveAfterRetirementBytes": after.activeMemory,
                    "mlxCacheAfterRetirementBytes": after.cacheMemory,
                    "mlxPeakIncludingLoadBytes": after.peakMemory,
                    "mlxConfiguredCacheLimitBytes": limits.cacheLimitBytes,
                    "mlxConfiguredMemoryLimitBytes": limits.memoryLimitBytes,
                    "kvGrantBytes": report.grant.grantBytes,
                    "shortAnswerOnly": true, "sustainedGenerationQualified": false,
                ]
                print("DIFFUSION_LONG_CONTEXT " + String(decoding: try JSONSerialization.data(
                    withJSONObject: record, options: [.sortedKeys]), as: UTF8.self))
            }
        }
    }
}

private final class DiffusionLongContextBundleAnchor: XCTestCase {}
