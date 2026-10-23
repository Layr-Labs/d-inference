import ArgumentParser
import Testing

@testable import darkbloom

@Suite("Scheduler-prefill prompt controls")
struct BenchmarkSchedulerPrefillPromptTests {
    @Test func fixedPromptIsExplicitAndDefaultsOff() throws {
        let defaults = try Benchmark.parse(["--scheduler-prefill"])
        #expect(!defaults.prefillFixedPrompt)
        #expect(defaults.schedulerPrefillOptionError() == nil)

        let fixed = try Benchmark.parse([
            "--scheduler-prefill", "--prefill-fixed-prompt",
            "--prefill-lengths", "1024,4096", "--prefill-iterations", "10",
        ])
        #expect(fixed.schedulerPrefill && fixed.prefillFixedPrompt)
        #expect(fixed.prefillLengths == "1024,4096" && fixed.prefillIterations == 10)
        #expect(fixed.benchmarkModeConflict() == nil)
        #expect(fixed.schedulerPrefillOptionError() == nil)
    }

    @Test func fixedPromptIsRejectedOutsideSchedulerPrefill() throws {
        for mode in [
            [], ["--sweep"], ["--scheduler-prefill-decision"], ["--arrival-invariance"],
            ["--parity"], ["--runtime-generation"],
            ["--teacher-forced-input", "/synthetic/scores.json"],
        ] {
            let command = try Benchmark.parse(mode + ["--prefill-fixed-prompt"])
            #expect(command.schedulerPrefillOptionError()
                == "--prefill-fixed-prompt requires --scheduler-prefill")
        }
        let conflict = try Benchmark.parse([
            "--scheduler-prefill", "--prefill-fixed-prompt", "--sweep",
        ])
        #expect(conflict.benchmarkModeConflict() != nil)
    }

    @Test
    @MainActor
    func invalidFixedPromptExitsBeforeConfigurationOrRuntimeLoading() async throws {
        for mode in [[], ["--sweep"], ["--scheduler-prefill-decision"]] {
            var command = try Benchmark.parse(mode + [
                "--prefill-fixed-prompt", "--config", "/missing/fixed-prompt-test/provider.toml",
            ])
            await #expect(throws: ExitCode(2)) { try await command.run() }
        }
    }

    @Test func fixedPromptKeepsLengthAdmissionAndOtherModeDefaults() throws {
        let singleton = try Benchmark.parse([
            "--scheduler-prefill", "--prefill-fixed-prompt", "--prefill-lengths", "1",
        ])
        #expect(singleton.schedulerPrefillOptionError()
            == "--scheduler-prefill requires --prefill-lengths greater than 1")
        let sweep = try Benchmark.parse(["--sweep", "--prefill-lengths", "1"])
        #expect(!sweep.prefillFixedPrompt && sweep.schedulerPrefillOptionError() == nil)
        let ordinary = try Benchmark.parse([])
        #expect(!ordinary.prefillFixedPrompt && ordinary.schedulerPrefillOptionError() == nil)
    }
}
