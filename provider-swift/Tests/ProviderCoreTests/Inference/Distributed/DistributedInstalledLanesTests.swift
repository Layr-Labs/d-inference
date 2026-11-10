import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import ProviderCore

/// Which installed pairs serve batch lanes, and how many, by adapter and mode.
struct DistributedInstalledLanesTests {
    typealias Plan = DistributedInstalledPlan

    /// GLM tensor parallel serves the width its placement saved for both Macs' memory (`ClusterPlacementTensorWidth`),
    /// and one request at a time without one, as every other tensor-parallel family does.
    @Test func glmTensorParallelServesItsSavedWidth() {
        #expect(Plan.defaultBatchLanes(adapter: .glm5NextLayerStage, mode: .tensorParallel, hasPrivateImages: false) == 1)
        // Its image candidate is not served in this mode; the lanes are text.
        #expect(Plan.defaultBatchLanes(adapter: .glm5NextLayerStage, mode: .tensorParallel, hasPrivateImages: true) == 1)
        #expect(Plan.tensorParallelLaneAdapters.contains(.glm5NextLayerStage))
        for lanes in 2...8 {
            #expect(Plan.lanesRetireAlone(adapter: .glm5NextLayerStage, mode: .tensorParallel, hasPrivateImages: false, lanes: lanes))
        }
        #expect(ClusterRuntimeAdapter.glm5NextLayerStage.savesTensorParallelWidth(runtimeModelID: ClusterGLMImageCandidate.runtimeModelID))
    }

    @Test func gemmaTensorParallelServesExplicitLanesWithSingletonDefault() {
        #expect(Plan.defaultBatchLanes(adapter: .gemma4LayerStage, mode: .tensorParallel, hasPrivateImages: false) == 1)
        #expect(Plan.tensorParallelLaneAdapters.contains(.gemma4LayerStage))
        for lanes in 2...8 {
            #expect(Plan.lanesRetireAlone(adapter: .gemma4LayerStage, mode: .tensorParallel, hasPrivateImages: false, lanes: lanes))
        }
        #expect(!Plan.lanesRetireAlone(adapter: .gemma4LayerStage, mode: .tensorParallel, hasPrivateImages: false, lanes: 1))
    }

    @Test func mimoTensorParallelServesOneRequestAtATime() {
        #expect(Plan.defaultBatchLanes(adapter: .mimoV26LayerStage, mode: .tensorParallel, hasPrivateImages: false) == nil)
        #expect(!Plan.tensorParallelLaneAdapters.contains(.mimoV26LayerStage))
        for lanes in 1...8 {
            #expect(!Plan.lanesRetireAlone(adapter: .mimoV26LayerStage, mode: .tensorParallel, hasPrivateImages: false, lanes: lanes))
        }
        #expect(Plan.defaultBatchLanes(adapter: .mimoV26LayerStage, mode: .pipeline, hasPrivateImages: false) == Plan.defaultBatchLanes)
    }

    @Test func lightningSupportsExplicitPipelineLanesWithSingletonDefault() {
        #expect(Plan.laneAdapters.contains(.nemotronH))
        #expect(Plan.defaultBatchLanes(adapter: .nemotronH, mode: .pipeline, hasPrivateImages: false) == 1)
        #expect(Plan.defaultBatchLanes(adapter: .nemotronH, mode: .pipeline, hasPrivateImages: true) == nil)
        for mode in ClusterGenerationMode.allCases where mode != .pipeline {
            #expect(Plan.defaultBatchLanes(adapter: .nemotronH, mode: mode, hasPrivateImages: false) == nil)
        }
    }

    @Test func mimoPagedTextPipelineKeepsSingletonDefaultAndExplicitLaneEligibility() {
        #expect(Plan.laneAdapters.contains(.mimoV26LayerStage))
        #expect(Plan.defaultBatchLanes(adapter: .mimoV26LayerStage, mode: .pipeline, hasPrivateImages: false) == 1)
        #expect(Plan.defaultBatchLanes(adapter: .mimoV26LayerStage, mode: .pipeline, hasPrivateImages: true) == nil)
        #expect(!Plan.laneAdapters.contains(.mimoV26ImageCandidate))
        for mode in ClusterGenerationMode.allCases where mode != .pipeline {
            #expect(Plan.defaultBatchLanes(adapter: .mimoV26LayerStage, mode: mode, hasPrivateImages: false) == nil)
        }
    }

    /// A Gemma pipeline serves the width its setup saved with serial prefill. Saved without one, as every guided
    /// setup is (`ClusterPlacementPipelineWidth`), it serves one request at a time under either schedule, as every
    /// family does.
    @Test func gemmaPipelineWithoutASavedWidthServesOneLane() {
        #expect(Plan.defaultBatchLanes(adapter: .gemma4LayerStage, mode: .pipeline, hasPrivateImages: false) == Plan.defaultBatchLanes)
        #expect(Plan.defaultBatchLanes == 1)
        #expect(Plan.defaultBatchLanes(adapter: .gemma4LayerStage, mode: .pipeline, hasPrivateImages: true) == nil)
        // Gemma 4 tensor parallel's own lanes are its batch driver's (checked above).
        for mode in ClusterGenerationMode.allCases where mode != .pipeline && mode != .tensorParallel {
            #expect(Plan.defaultBatchLanes(adapter: .gemma4LayerStage, mode: mode, hasPrivateImages: false) == nil)
        }
        #expect(Plan.defaultBatchLanes(adapter: .gemma4LayerStage, mode: .tensorParallel, hasPrivateImages: false)
            == Plan.defaultBatchLanes)
        // A cancelled lane of a saved Gemma width retires alone, as every pipeline lane adapter's does.
        #expect(Plan.lanesRetireAlone(adapter: .gemma4LayerStage, mode: .pipeline, hasPrivateImages: false, lanes: 4))
    }

    @Test func otherModesAndFamiliesKeepTheirLanes() {
        // GLM's pipeline still serves one request at a time.
        #expect(Plan.defaultBatchLanes(adapter: .glm5NextLayerStage, mode: .pipeline, hasPrivateImages: false) == nil)
        // The pipeline's lane adapters keep their default, text only.
        for adapter in Plan.laneAdapters {
            #expect(Plan.defaultBatchLanes(adapter: adapter, mode: .pipeline, hasPrivateImages: false) == Plan.defaultBatchLanes)
            #expect(Plan.defaultBatchLanes(adapter: adapter, mode: .pipeline, hasPrivateImages: true) == nil)
            let tensorParallel: Int? = Plan.tensorParallelLaneAdapters.contains(adapter) ? Plan.defaultBatchLanes : nil
            #expect(Plan.defaultBatchLanes(adapter: adapter, mode: .tensorParallel, hasPrivateImages: false) == tensorParallel)
        }
        for mode in ClusterGenerationMode.allCases where mode != .pipeline && mode != .tensorParallel {
            for adapter in ClusterRuntimeAdapter.allCases {
                #expect(Plan.defaultBatchLanes(adapter: adapter, mode: mode, hasPrivateImages: false) == nil)
            }
        }
        #expect(Plan.defaultBatchLanes(adapter: .mimoV26ImageCandidate, mode: .pipeline, hasPrivateImages: true) == nil)
    }
}
