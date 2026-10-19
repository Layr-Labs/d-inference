// Benchmark report shapes that need no model: the ordinary benchmark's
// averages and table, model selection, the scheduler-prefill JSON payload,
// and the MTP production stop-token policy.

import Foundation
import Testing

@testable import ProviderBenchmark
@testable import ProviderCore

@Suite("benchmark reports and selection without a model")
struct ModelBenchmarkReportTests {
    private func iteration(
        _ index: Int, prompt: Int, completion: Int, prefill: Double, decode: Double, total: Double
    ) -> BenchmarkIterationResult {
        BenchmarkIterationResult(
            iteration: index, promptTokens: prompt, completionTokens: completion,
            prefillLatencyMs: prefill, decodeTokensPerSecond: decode, totalTimeMs: total)
    }

    @Test("averages are arithmetic means and token counts use integer division")
    func reportAverages() {
        let report = BenchmarkReport(
            modelID: "fixture", modelPath: "/fixture", prompt: "hello",
            iterations: [
                iteration(1, prompt: 10, completion: 20, prefill: 100, decode: 30, total: 1000),
                iteration(2, prompt: 11, completion: 21, prefill: 200, decode: 50, total: 3000),
            ],
            hardwareDescription: "fixture hardware")
        #expect(report.avgPrefillLatencyMs == 150)
        #expect(report.avgDecodeTokensPerSecond == 40)
        #expect(report.avgTotalTimeMs == 2000)
        #expect(report.avgPromptTokens == 10)
        #expect(report.avgCompletionTokens == 20)
        report.printTable()
    }

    @Test("a report with no iterations averages to zero")
    func emptyReport() {
        let report = BenchmarkReport(
            modelID: "fixture", modelPath: "/fixture", prompt: "hello", iterations: [],
            hardwareDescription: "fixture hardware")
        #expect(report.avgPrefillLatencyMs == 0)
        #expect(report.avgDecodeTokensPerSecond == 0)
        #expect(report.avgTotalTimeMs == 0)
        #expect(report.avgPromptTokens == 0)
        #expect(report.avgCompletionTokens == 0)
        report.printTable()
    }

    @Test("a preferred model is matched by id, otherwise the largest model is chosen")
    func modelSelection() {
        let models = ["small", "medium", "large"].enumerated().map {
            ModelInfo(id: $0.element, sizeBytes: UInt64($0.offset + 1), estimatedMemoryGb: Double($0.offset))
        }
        #expect(ModelBenchmark.selectModel(models: models, preferredModel: "medium")?.id == "medium")
        #expect(ModelBenchmark.selectModel(models: models, preferredModel: "absent") == nil)
        #expect(ModelBenchmark.selectModel(models: models, preferredModel: nil)?.id == "large")
        #expect(ModelBenchmark.selectModel(models: [], preferredModel: nil) == nil)
        #expect(ModelBenchmark.defaultPrompt == "Write a short story about a robot learning to paint.")
        #expect(ModelBenchmark.defaultIterations == 3)
        #expect(ModelBenchmark.defaultMaxTokens == 256)
    }

    @Test("the scheduler-prefill payload round-trips with sorted keys")
    func schedulerPrefillReportJSON() throws {
        let sample = SchedulerPrefillBenchmarkReport.Sample(
            strategy: SchedulerPrefillBenchmark.strategyLabel, promptTokens: 128, iteration: 1,
            ttftMs: 12.5, peakMemoryBytes: 2048, activeMemoryBytes: 1024,
            msPerPrefillToken: 12.5 / 127, resolvedKVBackend: "contiguous")
        let report = SchedulerPrefillBenchmarkReport(
            schemaVersion: SchedulerPrefillBenchmarkReport.currentSchemaVersion,
            modelID: "fixture", modelPath: "/fixture", promptLengths: [128],
            strategies: [SchedulerPrefillBenchmark.strategyLabel], iterations: 1,
            gemmaOptimizations: BenchmarkGemmaOptimizations(
                settings: GemmaOptimizationSettings(), getenv: { _ in nil }),
            kvBackend: BenchmarkKVBackend(selection: "auto", resolved: ["contiguous"]),
            soloPrefillStripeTokens: nil, samples: [sample])
        let json = try report.jsonString()
        let decoded = try JSONDecoder().decode(
            SchedulerPrefillBenchmarkReport.self, from: Data(json.utf8))
        #expect(decoded.schemaVersion == 4)
        #expect(decoded.strategies == ["cbv2"])
        #expect(decoded.samples.first?.resolvedKVBackend == "contiguous")
        #expect(decoded.samples.first?.peakMemoryBytes == 2048)
        #expect(decoded.soloPrefillStripeTokens == nil)
        let iterations = try #require(json.range(of: "\"iterations\""))
        let samples = try #require(json.range(of: "\"samples\""))
        #expect(iterations.lowerBound < samples.lowerBound)
    }

    @Test("the MTP stop set adds the tokenizer EOS and every convertible extra token")
    func mtpStopTokens() {
        let convert: (String) -> Int? = { ["<end>": 42, "<eot>": 43][$0] }
        let base = ModelEOSPolicy.effectiveEOSTokenIds(
            modelId: "fixture/plain", modelType: "llama", base: [1], tokenToId: convert)
        let stop = MTPBenchmarkProductionPolicy.stopTokenIDs(
            modelID: "fixture/plain", modelType: "llama", baseConfigTokenIDs: [1],
            tokenizerEOSTokenID: 7, extraEOSTokens: ["<end>", "<unknown>", "<eot>"],
            convertTokenToID: convert)
        #expect(stop == base.union([7, 42, 43]))
        #expect(stop.contains(1))

        let noTokenizerEOS = MTPBenchmarkProductionPolicy.stopTokenIDs(
            modelID: "fixture/plain", modelType: "llama", baseConfigTokenIDs: [1],
            tokenizerEOSTokenID: nil, extraEOSTokens: [], convertTokenToID: convert)
        #expect(noTokenizerEOS == base)
    }
}
