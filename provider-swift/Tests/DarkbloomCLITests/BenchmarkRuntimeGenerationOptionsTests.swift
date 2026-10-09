import ArgumentParser
import Testing
@testable import darkbloom

@Suite("Runtime-generation benchmark controls")
struct BenchmarkRuntimeGenerationOptionsTests {
    @Test func productionModeAndPrecisionControlsParse() throws {
        let command = try Benchmark.parse([
            "--runtime-generation", "--model", "gpt-oss-20b", "--kv-backend", "paged",
            "--kv-quantization", "native", "--runtime-prompt-file", "/tmp/public-prompt.txt",
            "--runtime-prompt-date", "2026-10-09", "--runtime-mtp",
        ])
        #expect(command.runtimeGeneration && command.runtimeMtp)
        #expect(command.kvQuantization == "native")
        #expect(command.runtimePromptFile == "/tmp/public-prompt.txt")
        #expect(command.runtimePromptDate == "2026-10-09")
        #expect(command.benchmarkModeConflict() == nil)
    }

    @Test func incompatibleModesAndUnscopedRuntimeOptionsAreRefused() throws {
        for mode in ["--sweep", "--parity", "--scheduler-prefill", "--arrival-invariance"] {
            #expect(try Benchmark.parse(["--runtime-generation", mode]).benchmarkModeConflict() != nil)
        }
        #expect(try Benchmark.parse(["--runtime-mtp"]).benchmarkModeConflict() != nil)
        #expect(try Benchmark.parse(["--runtime-prompt-file", "/tmp/input"]).benchmarkModeConflict() != nil)
        #expect(try Benchmark.parse(["--runtime-generation"])
            .nativeBlockModeError(modelType: "diffusion_gemma") != nil)
        let ordinary = try Benchmark.parse([])
        #expect(!ordinary.runtimeGeneration && ordinary.kvQuantization == nil)
    }
}
