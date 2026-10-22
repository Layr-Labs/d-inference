import Foundation
import Testing
@testable import DarkbloomClusterRuntime

// A MiMo stage process admits the hand-off qualification fault exactly as the
// dense adapter does, and never drops it: before this, a MiMo worker started
// with the qualification flag read the switch nowhere, so a hand-off fault run
// (a corrupted or stalled segment) ran a clean hand-off and looked like a pass.
// No model, no GPU.

@Suite("MiMo: the hand-off qualification fault is admitted, never silently ignored")
struct MiMoQualificationFaultTests {
    static let name = QwenResidentQualificationSwitches.faultEnvironmentName

    @Test func aPermittedPhaseSplitProcessCommitsTheFaultItWasGiven() throws {
        let corrupt = try MiMoQualificationFault.admit(environment: [Self.name: "handoff_corrupt_segment=3"],
            qualification: .permittedByExplicitFlag, mode: .phaseSplit)
        #expect(corrupt?.corruptSegment == 3 && corrupt?.stallAfterSegment == nil)
        let stall = try MiMoQualificationFault.admit(environment: [Self.name: "handoff_stall_after_segment=2:500"],
            qualification: .permittedByExplicitFlag, mode: .phaseSplit)
        #expect(stall?.stallAfterSegment == 2 && stall?.stallMilliseconds == 500 && stall?.corruptSegment == nil)
        #expect(try MiMoQualificationFault.admit(environment: [:], qualification: .permittedByExplicitFlag, mode: .phaseSplit) == nil)
        #expect(try MiMoQualificationFault.admit(environment: [:], qualification: .refused, mode: .phaseSplit) == nil)
    }

    @Test func aFaultThisProcessCannotCommitIsRefused() {
        // No hand-off in a pipeline: refused, not ignored.
        #expect(throws: (any Error).self) {
            _ = try MiMoQualificationFault.admit(environment: [Self.name: "handoff_corrupt_segment=1"],
                qualification: .permittedByExplicitFlag, mode: .pipeline)
        }
        // A MiMo stage keeps no prompt-prefix disk tier.
        #expect(throws: (any Error).self) {
            _ = try MiMoQualificationFault.admit(environment: [Self.name: "prefix_ssd_restore_fail=1"],
                qualification: .permittedByExplicitFlag, mode: .phaseSplit)
        }
        // Without the explicit qualification flag the switch is refused, as for every family.
        #expect(throws: (any Error).self) {
            _ = try MiMoQualificationFault.admit(environment: [Self.name: "handoff_corrupt_segment=1"],
                qualification: .refused, mode: .phaseSplit)
        }
        #expect(throws: (any Error).self) {
            _ = try MiMoQualificationFault.admit(environment: [Self.name: "handoff_corrupt_segment=x"],
                qualification: .permittedByExplicitFlag, mode: .phaseSplit)
        }
    }
}
