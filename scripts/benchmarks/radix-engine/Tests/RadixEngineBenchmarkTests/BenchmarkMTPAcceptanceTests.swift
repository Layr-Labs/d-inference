import MLXLMCommon
import ProviderCore
import Testing
@testable import radix_engine

struct BenchmarkMTPAcceptanceTests {
    private let base = ["radix-engine", "/model", "/input", "/output", "cache-off", "mtp-on", "paged", "ssd"]

    @Test func defaultRemainsExact() throws {
        #expect(try BenchmarkOptions(base).mtpAcceptance == "exact")
    }

    @Test func rejectsMalformedMissingAndDuplicateSelections() {
        for flags in [["--mtp-acceptance"], ["--mtp-acceptance", "unknown"],
            ["--mtp-acceptance", "EXACT"], ["--mtp-acceptance", " typical"],
            ["--mtp-acceptance", "typical:0.1"],
            ["--mtp-acceptance", "exact", "--mtp-acceptance", "typical"]] {
            #expect(throws: (any Error).self) { try BenchmarkOptions(base + flags) }
        }
    }

    #if RADIX_CANDIDATE
    @Test func selectionsResolveToInstalledConfigAndMetricRecords() throws {
        for mode in ["exact", "typical"] {
            let options = try BenchmarkOptions(base + ["--mtp-acceptance", mode])
            let acceptance = try #require(MTPAcceptancePolicy.parse(options.mtpAcceptance))
            let config = CBv2MTPConfig(enabled: true, acceptance: acceptance)
            #expect(config.acceptance.name == mode)
            var metrics = CBv2MTPMetrics()
            metrics.acceptance = config.acceptance
            metrics.rounds = 7
            metrics.draftedTokens = 14
            let record = BenchmarkMetrics.mtpRecord(metrics)
            #expect(record["acceptance"] as? String == mode)
            #expect(record["rounds"] as? Int == 7)
            #expect(record["proposed_tokens"] as? Int == 14)
        }
    }
    #else
    @Test func baselineRefusesNewControl() {
        for mode in ["exact", "typical"] {
            #expect(throws: (any Error).self) { try BenchmarkOptions(base + ["--mtp-acceptance", mode]) }
        }
    }
    #endif
}
