import ArgumentParser
import Testing

@testable import darkbloom

@Suite("benchmark quality corpus options")
struct BenchmarkQualityCorpusOptionsTests {
    @Test
    func qualityModeParsesDefaults() throws {
        let command = try Benchmark.parse([
            "--model", "org/qwen",
            "--quality-corpus", "Benchmarks/QualityCorpus/qwen-quality-v1.json",
        ])

        #expect(command.qualityCorpus
            == "Benchmarks/QualityCorpus/qwen-quality-v1.json")
        #expect(command.qualityMaxTokens == nil)
        #expect(command.qualityRunLabel == nil)
        #expect(command.qualityBaselineReport == nil)
    }

    @Test
    func qualityModeAcceptsComparisonOptions() throws {
        let command = try Benchmark.parse([
            "--model", "org/qwen",
            "--quality-corpus", "corpus.json",
            "--quality-max-tokens", "128",
            "--quality-run-label", "top4-layer39",
            "--quality-baseline-report", "baseline.json",
            "--quality-output", "candidate.json",
            "--kv-backend", "contiguous",
        ])

        #expect(command.qualityMaxTokens == 128)
        #expect(command.qualityRunLabel == "top4-layer39")
        #expect(command.qualityBaselineReport == "baseline.json")
        #expect(command.qualityOutput == "candidate.json")
        #expect(command.kvBackend == "contiguous")
    }

    @Test
    func qualityModeRequiresExplicitModelAndValidTokenWindow() {
        #expect(throws: (any Error).self) {
            _ = try Benchmark.parse([
                "--quality-corpus", "corpus.json",
            ])
        }
        for invalid in [Int.min, -1, 0, 31, 4_097, Int.max] {
            #expect(throws: (any Error).self) {
                _ = try Benchmark.parse([
                    "--model", "org/qwen",
                    "--quality-corpus", "corpus.json",
                    "--quality-max-tokens", String(invalid),
                ])
            }
        }
    }

    @Test
    func qualityModeCannotCombineWithOtherEngineModes() {
        for mode in [
            "--sweep",
            "--scheduler-prefill",
            "--arrival-invariance",
            "--parity",
        ] {
            #expect(throws: (any Error).self) {
                _ = try Benchmark.parse([
                    "--model", "org/qwen",
                    "--quality-corpus", "corpus.json",
                    mode,
                ])
            }
        }
    }

    @Test
    func qualityOptionsRequireQualityMode() {
        for (option, value) in [
            ("--quality-max-tokens", "64"),
            ("--quality-run-label", "baseline"),
            ("--quality-baseline-report", "baseline.json"),
            ("--quality-output", "report.json"),
        ] {
            #expect(throws: (any Error).self) {
                _ = try Benchmark.parse([
                    option, value,
                ])
            }
        }
    }
}
