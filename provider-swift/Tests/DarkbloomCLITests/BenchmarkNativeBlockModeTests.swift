import ArgumentParser
import Testing

@testable import darkbloom

struct BenchmarkNativeBlockModeTests {
    @Test func ordinaryNativeBlockCommandHonorsBackendWithoutARMode() throws {
        let command = try Benchmark.parse(["--kv-backend", "paged", "--iterations", "2", "--max-tokens", "512"])
        #expect(command.nativeBlockModeError(modelType: "diffusion_gemma") == nil)
        #expect(command.kvBackend == "paged")
    }

    @Test func autoregressiveDiagnosticsRefuseNativeDiffusionOnly() throws {
        for arguments in [["--sweep"], ["--scheduler-prefill"], ["--arrival-invariance"],
            ["--parity"], ["--teacher-forced-input", "fixture.json", "--model", "fixture"]] {
            let command = try Benchmark.parse(arguments)
            #expect(command.nativeBlockModeError(modelType: "diffusion_gemma") != nil)
            for family in [nil, "qwen4_exp", "gemma4", "prism_hadamard_qwen35", "nemotron_h"] {
                #expect(command.nativeBlockModeError(modelType: family) == nil)
            }
        }
    }
}
