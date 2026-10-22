import Foundation
import Testing

@testable import ProviderBenchmark
@testable import ProviderCore

/// Pure prompt construction and report compatibility; no model or MLX arrays.
@Suite("Scheduler-prefill prompt fixtures and provenance")
struct SchedulerPrefillPromptTests {
    @Test func fixedMeasuredPromptsMatchTheirFullContextWarmup() {
        let base = Array(100..<123)
        for length in [2, 128, 1024, 4096] {
            let warmup = SchedulerPrefillBenchmark.makePrompt(
                baseTokens: base, length: length, iteration: 0, mode: .fixed)
            #expect(warmup.offset == 0 && warmup.tokens.count == length)
            #expect(warmup.tokens == (0..<length).map { base[$0 % base.count] })
            for iteration in [1, 2, 8, 17] {
                let measured = SchedulerPrefillBenchmark.makePrompt(
                    baseTokens: base, length: length, iteration: iteration, mode: .fixed)
                #expect(measured.offset == 0)
                #expect(measured.tokens == warmup.tokens)
            }
        }
    }

    @Test func defaultPromptsRetainTheExistingRotationAndZeroOffsetWarmup() {
        let base = Array(100..<123)
        for iteration in [0, 1, 2, 8] {
            let prompt = SchedulerPrefillBenchmark.makePrompt(
                baseTokens: base, length: 128, iteration: iteration)
            #expect(prompt.offset == iteration * 17)
            #expect(prompt.tokens == (0..<128).map { base[($0 + iteration * 17) % base.count] })
        }
        let first = SchedulerPrefillBenchmark.makePrompt(baseTokens: base, length: 128, iteration: 1)
        let second = SchedulerPrefillBenchmark.makePrompt(baseTokens: base, length: 128, iteration: 2)
        #expect(first.tokens != second.tokens)
    }

    @Test func fixedBootstrapIsAPrefixAndEmptySeedKeepsFallback() {
        let base = Array(100..<123)
        let bootstrap = SchedulerPrefillBenchmark.makePrompt(
            baseTokens: base, length: 128, iteration: 0, mode: .fixed)
        let measured = SchedulerPrefillBenchmark.makePrompt(
            baseTokens: base, length: 4096, iteration: 4, mode: .fixed)
        #expect(Array(measured.tokens.prefix(128)) == bootstrap.tokens)
        let empty = SchedulerPrefillBenchmark.makePrompt(
            baseTokens: [], length: 3, iteration: 4, mode: .fixed)
        #expect(empty.tokens == [0, 0, 0] && empty.offset == 0)
    }

    @Test(arguments: [SchedulerPrefillBenchmark.PromptMode.rotating, .fixed])
    func reportRecordsModeAndEachUnwrappedOffset(mode: SchedulerPrefillBenchmark.PromptMode) throws {
        let source = report(mode: mode)
        let json = try source.jsonString()
        let decoded = try JSONDecoder().decode(
            SchedulerPrefillBenchmarkReport.self, from: Data(json.utf8))
        #expect(decoded.schemaVersion == 4)
        #expect(decoded.promptMode == mode && decoded.warmupPromptOffset == 0)
        #expect(decoded.samples.map(\.promptOffset) == (mode == .fixed ? [0, 0] : [17, 34]))
        #expect(decoded.samples.map(\.iteration) == [1, 2])
        #expect(decoded.samples.allSatisfy { $0.promptTokens == 128 })
    }

    @Test func legacyReportWithoutPromptMetadataRemainsUnknown() throws {
        let data = try JSONEncoder().encode(report(mode: .fixed))
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        var object = try #require(jsonObject as? [String: Any])
        object.removeValue(forKey: "promptMode")
        object.removeValue(forKey: "warmupPromptOffset")
        var samples = try #require(object["samples"] as? [[String: Any]])
        for index in samples.indices { samples[index].removeValue(forKey: "promptOffset") }
        object["samples"] = samples
        let legacy = try JSONDecoder().decode(
            SchedulerPrefillBenchmarkReport.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.schemaVersion == 4 && legacy.samples.count == 2)
        #expect(legacy.promptMode == nil && legacy.warmupPromptOffset == nil)
        #expect(legacy.samples.allSatisfy { $0.promptOffset == nil })
        let reencoded = try legacy.jsonString()
        #expect(!reencoded.contains("promptMode"))
        #expect(!reencoded.contains("warmupPromptOffset"))
        #expect(!reencoded.contains("promptOffset"))
    }

    private func report(mode: SchedulerPrefillBenchmark.PromptMode) -> SchedulerPrefillBenchmarkReport {
        let samples = (1...2).map { iteration in
            let prompt = SchedulerPrefillBenchmark.makePrompt(
                baseTokens: [1, 2, 3], length: 128, iteration: iteration, mode: mode)
            return SchedulerPrefillBenchmarkReport.Sample(
                strategy: "cbv2", promptTokens: 128, iteration: iteration,
                ttftMs: 12.5, peakMemoryBytes: 2048, activeMemoryBytes: 1024,
                msPerPrefillToken: 12.5 / 127, resolvedKVBackend: "contiguous",
                promptOffset: prompt.offset)
        }
        return SchedulerPrefillBenchmarkReport(
            schemaVersion: SchedulerPrefillBenchmarkReport.currentSchemaVersion,
            modelID: "fixture", modelPath: "/fixture", promptLengths: [128],
            strategies: ["cbv2"], iterations: 2,
            gemmaOptimizations: BenchmarkGemmaOptimizations(
                settings: GemmaOptimizationSettings(), getenv: { _ in nil }),
            kvBackend: BenchmarkKVBackend(selection: "auto", resolved: ["contiguous"]),
            soloPrefillStripeTokens: 2048, samples: samples,
            promptMode: mode, warmupPromptOffset: 0)
    }
}
