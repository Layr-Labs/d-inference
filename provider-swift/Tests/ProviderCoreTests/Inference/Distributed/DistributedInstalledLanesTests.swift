import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import ProviderCore

/// Which installed pairs serve batch lanes, and how many, by adapter and mode.
struct DistributedInstalledLanesTests {
    typealias Plan = DistributedInstalledPlan

    @Test func glmTensorParallelServesEightLanes() {
        #expect(Plan.defaultBatchLanes(adapter: .glm5NextLayerStage, mode: .tensorParallel, hasPrivateImages: false) == 8)
        // Its image candidate is not served in this mode; the lanes are text.
        #expect(Plan.defaultBatchLanes(adapter: .glm5NextLayerStage, mode: .tensorParallel, hasPrivateImages: true) == 8)
        #expect(Plan.tensorParallelBatchLanes == 8)
    }

    @Test func otherModesAndFamiliesKeepTheirLanes() {
        // GLM's pipeline still serves one request at a time.
        #expect(Plan.defaultBatchLanes(adapter: .glm5NextLayerStage, mode: .pipeline, hasPrivateImages: false) == nil)
        // The pipeline's lane adapters keep their default, text only.
        for adapter in Plan.laneAdapters {
            #expect(Plan.defaultBatchLanes(adapter: adapter, mode: .pipeline, hasPrivateImages: false) == Plan.defaultBatchLanes)
            #expect(Plan.defaultBatchLanes(adapter: adapter, mode: .pipeline, hasPrivateImages: true) == nil)
            #expect(Plan.defaultBatchLanes(adapter: adapter, mode: .tensorParallel, hasPrivateImages: false) == nil)
        }
        for mode in ClusterGenerationMode.allCases where mode != .pipeline && mode != .tensorParallel {
            for adapter in ClusterRuntimeAdapter.allCases {
                #expect(Plan.defaultBatchLanes(adapter: adapter, mode: mode, hasPrivateImages: false) == nil)
            }
        }
        #expect(Plan.defaultBatchLanes(adapter: .mimoV26LayerStage, mode: .pipeline, hasPrivateImages: false) == nil)
    }
}
