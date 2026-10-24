import Foundation
import Testing
@testable import DarkbloomClusterRuntime

struct QwenTensorParallelBatchSettingsTests {
    @Test func onlyExactQwen27SealedOwnersAdmitMultipleLanes() throws {
        let key = QwenBatchSettings.lanesEnvironmentName
        for lanes in 2...8 {
            let value = try QwenTensorParallelBatchSettings.resolve(model: .qwen38TwentySevenB,
                keyed: true, environment: [key: String(lanes)])
            #expect(value.lanes == lanes && value.backend == .paged)
            #expect(value.agreementFields.contains("lanes=\(lanes)"))
            #expect(value.agreementFields.contains(QwenTensorParallelBatchWire.agreement))
            #expect(throws: ProbeError.self) {
                try QwenTensorParallelBatchSettings.resolve(model: .qwen38TwentySevenB,
                    keyed: false, environment: [key: String(lanes)])
            }
        }
        for model in QwenRegisteredDenseModel.allCases where model != .qwen38TwentySevenB {
            let value = try QwenTensorParallelBatchSettings.resolve(model: model,
                keyed: false, environment: [key: "8"])
            #expect(value.lanes == 1 && value.agreementFields.isEmpty)
        }
    }

    @Test func keyedSingletonUsesTheSameRequestOwnedContractAsWiderCapacity() throws {
        let key = QwenBatchSettings.lanesEnvironmentName
        let singleton = try QwenTensorParallelBatchSettings.resolve(model: .qwen38TwentySevenB,
            keyed: true, environment: [:])
        let wider = try QwenTensorParallelBatchSettings.resolve(model: .qwen38TwentySevenB,
            keyed: true, environment: [key: "2"])
        #expect(singleton.lanes == 1 && singleton.requestOwned && singleton.backend == .paged)
        #expect(wider.requestOwned && wider.backend == singleton.backend)
        #expect(singleton.agreementFields.filter { !$0.hasPrefix("lanes=") }
            == wider.agreementFields.filter { !$0.hasPrefix("lanes=") })
        let legacyProbe = try QwenTensorParallelBatchSettings.resolve(model: .qwen38TwentySevenB,
            keyed: false, environment: [:])
        #expect(!legacyProbe.requestOwned && legacyProbe.agreementFields.isEmpty)
        for model in QwenRegisteredDenseModel.allCases where model != .qwen38TwentySevenB {
            #expect(try !QwenTensorParallelBatchSettings.resolve(model: model,
                keyed: true, environment: [key: "1"]).requestOwned)
        }
    }

    @Test func singletonAgreementAndInvalidBatchSettingsStayExplicit() throws {
        let key = QwenBatchSettings.lanesEnvironmentName
        for environment in [[:], [key: "1"]] {
            let value = try QwenTensorParallelBatchSettings.resolve(model: .qwen38TwentySevenB,
                keyed: false, environment: environment)
            #expect(value.lanes == 1 && value.agreementFields.isEmpty)
        }
        for raw in ["0", "9", "-1", "wide"] {
            #expect(throws: ProbeError.self) {
                try QwenTensorParallelBatchSettings.resolve(model: .qwen38TwentySevenB,
                    keyed: true, environment: [key: raw])
            }
        }
        let backend = ClusterStageKVBackendKind.environmentName
        let contiguous = try QwenTensorParallelBatchSettings.resolve(model: .qwen38TwentySevenB,
            keyed: true, environment: [key: "2", backend: "contiguous"])
        #expect(contiguous.backend == .contiguous && contiguous.agreementFields.contains("kv=contiguous"))
        #expect(throws: ProbeError.self) {
            try QwenTensorParallelBatchSettings.resolve(model: .qwen38TwentySevenB,
                keyed: true, environment: [key: "2", backend: "invalid"])
        }
    }
}
