import ArgumentParser
import Testing

@testable import darkbloom

@Suite("benchmark Qwen prefix options")
struct BenchmarkQwenPrefixOptionsTests {
    @Test
    func defaultBenchmarkDoesNotEnablePrefixReuse() throws {
        let command = try Benchmark.parse([])

        #expect(!command.qwenPrefixReuse)
        #expect(command.qwenPrefixCorpus == nil)
        #expect(command.qwenPrefixPromptTokens == nil)
        #expect(command.qwenPrefixDecodeTokens == nil)
        #expect(command.qwenPrefixIterations == nil)
        #expect(command.qwenPrefixOutput == nil)
    }

    @Test
    func prefixModeParsesDefaultsAndOverrides() throws {
        let defaults = try Benchmark.parse([
            "--model", "org/qwen",
            "--qwen-prefix-reuse",
            "--qwen-prefix-corpus", "Benchmarks/QwenPrefixReuse/qwen-prefix-natural-v1.json",
        ])
        #expect(defaults.qwenPrefixReuse)
        #expect(defaults.qwenPrefixPromptTokens == nil)
        #expect(defaults.qwenPrefixDecodeTokens == nil)
        #expect(defaults.qwenPrefixIterations == nil)

        let custom = try Benchmark.parse([
            "--model", "org/qwen",
            "--qwen-prefix-reuse",
            "--qwen-prefix-corpus", "corpus.json",
            "--qwen-prefix-prompt-tokens", "4096",
            "--qwen-prefix-decode-tokens", "32",
            "--qwen-prefix-iterations", "5",
            "--qwen-prefix-output", "report.json",
            "--kv-backend", "contiguous",
        ])
        #expect(custom.qwenPrefixPromptTokens == 4_096)
        #expect(custom.qwenPrefixDecodeTokens == 32)
        #expect(custom.qwenPrefixIterations == 5)
        #expect(custom.qwenPrefixOutput == "report.json")
        #expect(custom.kvBackend == "contiguous")
    }

    @Test
    func prefixModeRequiresExplicitInputsAndValidCounts() {
        #expect(throws: (any Error).self) {
            _ = try Benchmark.parse([
                "--qwen-prefix-reuse",
                "--qwen-prefix-corpus", "corpus.json",
            ])
        }
        #expect(throws: (any Error).self) {
            _ = try Benchmark.parse([
                "--model", "org/qwen",
                "--qwen-prefix-reuse",
            ])
        }
        for (option, invalid) in [
            ("--qwen-prefix-prompt-tokens", "1"),
            ("--qwen-prefix-decode-tokens", "1"),
            ("--qwen-prefix-iterations", "0"),
        ] {
            #expect(throws: (any Error).self) {
                _ = try Benchmark.parse([
                    "--model", "org/qwen",
                    "--qwen-prefix-reuse",
                    "--qwen-prefix-corpus", "corpus.json",
                    option, invalid,
                ])
            }
        }
    }

    @Test
    func prefixModeCannotCombineWithOtherEngineModes() {
        for mode in [
            "--sweep",
            "--scheduler-prefill",
            "--arrival-invariance",
            "--parity",
        ] {
            #expect(throws: (any Error).self) {
                _ = try Benchmark.parse([
                    "--model", "org/qwen",
                    "--qwen-prefix-reuse",
                    "--qwen-prefix-corpus", "corpus.json",
                    mode,
                ])
            }
        }
        #expect(throws: (any Error).self) {
            _ = try Benchmark.parse([
                "--model", "org/qwen",
                "--qwen-prefix-reuse",
                "--qwen-prefix-corpus", "prefix.json",
                "--quality-corpus", "quality.json",
            ])
        }
    }

    @Test
    func prefixOptionsRequirePrefixMode() {
        for (option, value) in [
            ("--qwen-prefix-corpus", "corpus.json"),
            ("--qwen-prefix-prompt-tokens", "8192"),
            ("--qwen-prefix-decode-tokens", "64"),
            ("--qwen-prefix-iterations", "3"),
            ("--qwen-prefix-output", "report.json"),
        ] {
            #expect(throws: (any Error).self) {
                _ = try Benchmark.parse([option, value])
            }
        }
    }
}
