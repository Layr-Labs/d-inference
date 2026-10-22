import ArgumentParser
import Testing

@testable import darkbloom

@Suite("Runtime-generation benchmark controls")
struct BenchmarkRuntimeGenerationOptionsTests {
    @Test func productionModeAndPrecisionControlsParse() throws {
        let command = try Benchmark.parse([
            "--runtime-generation", "--model", "gpt-oss-20b", "--kv-backend", "paged",
            "--kv-quantization", "native", "--kv-checkpoint-quantization", "k8v4",
            "--runtime-prompt-file", "/tmp/public-prompt.txt",
            "--runtime-prompt-date", "2026-10-09", "--runtime-mtp",
            "--runtime-assistant-directory", "/tmp/offline-assistant",
        ])
        #expect(command.runtimeGeneration && command.runtimeMtp)
        #expect(command.kvQuantization == "native")
        #expect(command.kvCheckpointQuantization == "k8v4")
        #expect(command.runtimePromptFile == "/tmp/public-prompt.txt")
        #expect(command.runtimePromptDate == "2026-10-09")
        #expect(command.runtimeAssistantDirectory == "/tmp/offline-assistant")
        #expect(command.benchmarkModeConflict() == nil)
        let concurrent = try Benchmark.parse([
            "--runtime-generation", "--runtime-mtp", "--runtime-concurrency", "1,2,4,8",
        ])
        #expect(concurrent.runtimeConcurrency == "1,2,4,8")
        #expect(!concurrent.runtimeStagger)
        #expect(concurrent.benchmarkModeConflict() == nil)
        let staggered = try Benchmark.parse([
            "--runtime-generation", "--runtime-concurrency", "4", "--runtime-stagger",
        ])
        #expect(staggered.runtimeStagger)
        #expect(staggered.benchmarkModeConflict() == nil)
    }

    @Test func incompatibleModesAndUnscopedRuntimeOptionsAreRefused() throws {
        for mode in ["--sweep", "--parity", "--scheduler-prefill", "--arrival-invariance"] {
            #expect(
                try Benchmark.parse(["--runtime-generation", mode]).benchmarkModeConflict() != nil)
        }
        #expect(try Benchmark.parse(["--runtime-mtp"]).benchmarkModeConflict() != nil)
        #expect(
            try Benchmark.parse(["--runtime-concurrency", "1,2"]).benchmarkModeConflict() != nil)
        #expect(
            try Benchmark.parse(["--runtime-generation", "--runtime-stagger"])
                .benchmarkModeConflict() != nil)
        #expect(
            try Benchmark.parse(["--runtime-prompt-file", "/tmp/input"]).benchmarkModeConflict()
                != nil)
        for arguments in [
            ["--runtime-assistant-directory", "/tmp/offline-assistant"],
            ["--runtime-generation", "--runtime-assistant-directory", "/tmp/offline-assistant"],
            ["--runtime-generation", "--runtime-mtp", "--runtime-assistant-directory", " "],
        ] {
            #expect(try Benchmark.parse(arguments).benchmarkModeConflict() != nil)
        }
        #expect(
            try Benchmark.parse(["--runtime-generation"])
                .nativeBlockModeError(modelType: "diffusion_gemma") != nil)
        let ordinary = try Benchmark.parse([])
        #expect(!ordinary.runtimeGeneration && ordinary.kvQuantization == nil
            && ordinary.kvCheckpointQuantization == nil)
    }
}
