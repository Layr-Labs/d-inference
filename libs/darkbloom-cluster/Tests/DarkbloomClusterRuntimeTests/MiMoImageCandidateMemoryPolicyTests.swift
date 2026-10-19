import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import DarkbloomClusterRuntime

@Suite("MiMo image candidate enforced memory startup policy (CPU)")
struct MiMoImageCandidateMemoryPolicyTests {
    private let candidate = ClusterMiMoImageCandidate.profileID
    private let name = QwenDenseStageLoadMeasurement.environmentName

    @Test func ordinaryCandidateAndRecordOnlyKeepEnforcedGatePolicy() throws {
        let ordinary = MiMoArithmeticEnvironment.requiredValues
        try QwenResidentQualificationSwitches.permittedByExplicitFlag.admit(environment:ordinary)
        #expect(try MiMoResidentAdmission.memoryMeasurementMode(runtimeProfile:candidate,environment:ordinary,
            existingModeWaivesRefusals:false) == nil)
        let recorded = ordinary.merging([name:"record"]) { _,new in new }
        #expect(try MiMoResidentAdmission.memoryMeasurementMode(runtimeProfile:candidate,environment:recorded,
            existingModeWaivesRefusals:false) == .record)
        // A test-owned recorder never starts the host sampler and waives no decision.
        let local = QwenDenseStageLoadMeasurement(samplesHost:false)
        try local.enable(.record,permittedBy:.permittedByExplicitFlag)
        #expect(local.isEnabled && !local.waivesRefusals)
    }

    @Test func candidateMeasureOrInheritedWaiverRefusesBeforeEnable() throws {
        let local = QwenDenseStageLoadMeasurement(samplesHost:false)
        #expect(throws:ProbeError.self) {
            let selected = try MiMoResidentAdmission.memoryMeasurementMode(runtimeProfile:candidate,
                environment:[name:"measure"],existingModeWaivesRefusals:false)
            if let selected { try local.enable(selected,permittedBy:.permittedByExplicitFlag) }
        }
        #expect(!local.isEnabled && !local.waivesRefusals && local.report == nil)
        let environments: [[String:String]] = [[:],[name:"record"],[name:"measure"]]
        for environment in environments {
            #expect(throws:ProbeError.self) {
                try MiMoResidentAdmission.memoryMeasurementMode(runtimeProfile:candidate,environment:environment,
                    existingModeWaivesRefusals:true)
            }
        }
        #expect(throws:ProbeError.self) {
            try MiMoResidentAdmission.memoryMeasurementMode(runtimeProfile:candidate,environment:[name:"unknown"],
                existingModeWaivesRefusals:false)
        }
    }

    @Test func textAndStandaloneMeasurementExperimentsRetainTheirPriorPolicy() throws {
        for profile in [nil,"registered_mimo_v26_flash_mopd_greedy_generation_v1"] as [String?] {
            for mode in QwenDenseStageLoadMeasurement.Mode.allCases {
                #expect(try MiMoResidentAdmission.memoryMeasurementMode(runtimeProfile:profile,
                    environment:[name:mode.rawValue],existingModeWaivesRefusals:false) == mode)
                #expect(try MiMoResidentAdmission.memoryMeasurementMode(runtimeProfile:profile,
                    environment:[name:mode.rawValue],existingModeWaivesRefusals:true) == mode)
            }
        }
        // The image profile does not grant qualification permission by itself.
        #expect(throws:ProbeError.self) { try QwenResidentQualificationSwitches.refused.admit(environment:[name:"record"]) }
        #expect(throws:ProbeError.self) { try QwenResidentQualificationSwitches.refused.admit(environment:[name:"measure"]) }
    }
}
