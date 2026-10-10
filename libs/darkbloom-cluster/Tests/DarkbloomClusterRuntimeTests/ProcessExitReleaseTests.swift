import Foundation
import Testing
@testable import DarkbloomClusterRuntime

// S00, the parts that need no exit: the status each routed signal ends with,
// the residency ceiling the product uses, and the qualification switch that
// asks a worker for a standing stage residency. The exit itself (release,
// dead-man, first claim wins, signals) is checked in child processes by
// Tests/ExitChecks/run.sh, since a claim here would end this test process.

@Suite struct ProcessExitReleaseTests {
    @Test func routedSignalsEndWithTheirOwnStatus() {
        #expect(ProcessForcedExit.status(forSignal: SIGTERM) == 143)
        #expect(ProcessForcedExit.status(forSignal: SIGINT) == 130)
        #expect(ProcessForcedExit.status(forSignal: SIGHUP) == 129)
        // The lifetime alarm ends like the lifetime deadline thread.
        #expect(ProcessForcedExit.status(forSignal: SIGALRM) == 124)
        #expect(ProcessForcedExit.defaultDeadManNanoseconds == 20_000_000_000)
        #expect(ProcessForcedExit.claim == nil, "a test process must never claim the exit")
    }

    @Test func stageResidencyLeavesTheProductsReserveUnwired() {
        let gib = 1 << 30
        // The larger of 16 GiB and a tenth of physical memory stays unwired,
        // and the recommended working set is never exceeded.
        #expect(ProcessStageResidency.ceiling(physicalBytes: 256 * gib, recommendedBytes: 250 * gib) == 256 * gib - (256 * gib / 10 + 1))
        #expect(ProcessStageResidency.ceiling(physicalBytes: 128 * gib, recommendedBytes: 120 * gib) == 112 * gib)
        #expect(ProcessStageResidency.ceiling(physicalBytes: 128 * gib, recommendedBytes: 96 * gib) == 96 * gib)
        #expect(ProcessStageResidency.ceiling(physicalBytes: 16 * gib, recommendedBytes: 12 * gib) == nil)
        #expect(ProcessStageResidency.ceiling(physicalBytes: 0, recommendedBytes: 1) == nil)
        #expect(ProcessStageResidency.policy == QwenResidentQualificationSwitches.stageResidencyValue)
    }

    @Test func stageResidencyIsAQualificationSwitch() throws {
        let name = QwenResidentQualificationSwitches.stageResidencyEnvironmentName
        let asked = [name: QwenResidentQualificationSwitches.stageResidencyValue]
        let refused = QwenResidentQualificationSwitches.refused, permitted = QwenResidentQualificationSwitches.permittedByExplicitFlag
        // Refused by name without the explicit flag, never silently ignored.
        do { try refused.admit(environment: asked); Issue.record("residency switch was not refused") }
        catch { #expect("\(error)".contains(name)) }
        #expect(throws: ProbeError.self) { _ = try refused.stageResidencyRequested(environment: asked) }
        try permitted.admit(environment: asked)
        #expect(try permitted.stageResidencyRequested(environment: asked))
        #expect(try !permitted.stageResidencyRequested(environment: [:]))
        #expect(throws: ProbeError.self) { _ = try permitted.stageResidencyRequested(environment: [name: "on"]) }
    }
}
