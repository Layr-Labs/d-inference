import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// The in-situ engine step-profile dump: renders the profiler's phase table
/// when `CBV2_STEP_PROFILE` armed it, a one-line status otherwise, and only
/// installs its SIGUSR1 handler when there is something to dump.
@Suite("Engine step-profile dump")
struct EngineStepProfileDumpTests {

    @Test func rendersAStatusLineWhenTheProfilerIsOff() {
        let text = EngineStepProfileDump.render(enabled: false, table: { "| never |" })
        #expect(text.contains("disabled"))
        #expect(text.contains("CBV2_STEP_PROFILE=1"))
        #expect(!text.contains("| never |"))
    }

    @Test func rendersTheProfilerTableWhenEnabled() {
        let table = "| phase | n | total ms |\n|---|---|---|\n| v2.step.wall[b4] | 3 | 1.0 |\n"
        let text = EngineStepProfileDump.render(enabled: true, table: { table })
        #expect(text.hasSuffix(table))
        #expect(text.contains("[bN]"))
    }

    @Test func doesNotArmASignalHandlerUnlessTheProfilerIsEnabled() {
        // The test process never sets CBV2_STEP_PROFILE, so the engine-side
        // switch is off and arming must be a no-op (returns false).
        guard !CBv2StepProfiler.enabled else { return }
        let armed = EngineStepProfileDump.armIfEnabled(sink: { _ in })
        #expect(!armed)
    }
}
