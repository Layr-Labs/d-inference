import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

struct QwenTensorParallelBatchSettingsTests {
    private static let tensorRows: [QwenRegisteredDenseModel] = [.qwen35NineB, .qwen38TwentySevenB,
                                                                 .qwen35ThirtyFiveBA3B, .qwen36ThirtyFiveBA3B]

    /// The worker's fence rule (`WorkerCollectiveSynchronization`) and the provider key on
    /// `ClusterRuntimeAdapter.qwenTensorParallelRuntimeModelIDs`; the runtime serves lanes for every row whose
    /// definition has tensor parallel. A new row must join both, or it would widen on another fence path.
    @Test func theProtocolsQwenTensorRowsAreExactlyTheRowsThatServeLanes() throws {
        let laneRows = QwenRegisteredDenseModel.allCases.filter {
            (try? QwenResidentModelDefinition(model: $0))?.supportedGenerationModes.contains(.tensorParallel) == true
        }
        #expect(Set(laneRows.map(\.rawValue)) == ClusterRuntimeAdapter.qwenTensorParallelRuntimeModelIDs)
        #expect(Set(laneRows) == Set(Self.tensorRows))
    }

    @Test func everySealedQwenTensorRowAdmitsOneToEightLanes() throws {
        let key = QwenBatchSettings.lanesEnvironmentName
        for model in Self.tensorRows {
            for lanes in 1...8 {
                let value = try QwenTensorParallelBatchSettings.resolve(model: model,
                    keyed: true, environment: [key: String(lanes)])
                #expect(value.lanes == lanes && value.backend == .paged)
                #expect(value.agreementFields.contains("lanes=\(lanes)"))
                #expect(value.agreementFields.contains(QwenTensorParallelBatchWire.agreement))
                #expect(value.agreementFields.contains("moe-rows-one-collective-v1") == value.routedExperts)
                #expect(value.routedExperts == [.qwen35ThirtyFiveBA3B, .qwen36ThirtyFiveBA3B].contains(model))
                // No unsealed pair serves a TP row: the single-lane path is retired.
                #expect(throws: ProbeError.self) {
                    try QwenTensorParallelBatchSettings.resolve(model: model,
                        keyed: false, environment: [key: String(lanes)])
                }
            }
        }
        for model in QwenRegisteredDenseModel.allCases where !Self.tensorRows.contains(model) {
            #expect(throws: ProbeError.self) {
                try QwenTensorParallelBatchSettings.resolve(model: model, keyed: true, environment: [:])
            }
        }
    }

    @Test func singletonUsesTheSameRequestOwnedContractAsWiderCapacity() throws {
        let key = QwenBatchSettings.lanesEnvironmentName
        for model in Self.tensorRows {
            let singleton = try QwenTensorParallelBatchSettings.resolve(model: model, keyed: true, environment: [:])
            let wider = try QwenTensorParallelBatchSettings.resolve(model: model, keyed: true, environment: [key: "2"])
            #expect(singleton.lanes == 1 && singleton.backend == .paged && wider.backend == singleton.backend)
            #expect(singleton.agreementFields.filter { !$0.hasPrefix("lanes=") }
                == wider.agreementFields.filter { !$0.hasPrefix("lanes=") })
        }
    }

    @Test func invalidBatchSettingsStayExplicit() throws {
        let key = QwenBatchSettings.lanesEnvironmentName
        for raw in ["0", "9", "-1", "wide"] {
            #expect(throws: ProbeError.self) {
                try QwenTensorParallelBatchSettings.resolve(model: .qwen38TwentySevenB,
                    keyed: true, environment: [key: raw])
            }
        }
        // Stage KV is paged only: the removed contiguous switch stops the load by name.
        let backend = ClusterStageKVBackendKind.environmentName
        // Every Qwen TP row, dense and routed, serves paged lanes only.
        for model in [QwenRegisteredDenseModel.qwen38TwentySevenB, .qwen35NineB, .qwen35ThirtyFiveBA3B] {
            let paged = try QwenTensorParallelBatchSettings.resolve(model: model,
                keyed: true, environment: [key: "2", backend: "paged"])
            #expect(paged.backend == .paged && paged.agreementFields.contains("kv=paged"))
            for raw in ["contiguous", "invalid"] {
                #expect(throws: ProbeError.self) {
                    try QwenTensorParallelBatchSettings.resolve(model: model,
                        keyed: true, environment: [key: "2", backend: raw])
                }
            }
        }
    }
}
