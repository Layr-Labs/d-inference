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

    @Test func gemmaTensorParallelServesExplicitLanesWithSingletonDefault() {
        #expect(Plan.defaultBatchLanes(adapter: .gemma4LayerStage, mode: .tensorParallel, hasPrivateImages: false) == 1)
        #expect(Plan.tensorParallelLaneAdapters[.gemma4LayerStage] == Plan.defaultBatchLanes)
        for lanes in 2...8 {
            #expect(Plan.lanesRetireAlone(adapter: .gemma4LayerStage, mode: .tensorParallel, hasPrivateImages: false, lanes: lanes))
        }
        #expect(!Plan.lanesRetireAlone(adapter: .gemma4LayerStage, mode: .tensorParallel, hasPrivateImages: false, lanes: 1))
    }

    @Test func mimoTensorParallelServesOneRequestAtATime() {
        #expect(Plan.defaultBatchLanes(adapter: .mimoV26LayerStage, mode: .tensorParallel, hasPrivateImages: false) == nil)
        #expect(Plan.tensorParallelLaneAdapters[.mimoV26LayerStage] == nil)
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

    /// A Gemma pipeline serves the width its placement saved (`ClusterPlacementPipelineWidth`). Saved without one, it
    /// serves one request at a time under either schedule, as every family does (review C1, P3).
    @Test func gemmaPipelineWithoutASavedWidthServesOneLane() {
        #expect(Plan.defaultBatchLanes(adapter: .gemma4LayerStage, mode: .pipeline, hasPrivateImages: false,
                                       prefillSchedule: .serial) == Plan.defaultBatchLanes)
        #expect(Plan.defaultBatchLanes == 1)
        // Lanes prefill serially: a saved lookahead keeps its schedule and one lane.
        #expect(Plan.defaultBatchLanes(adapter: .gemma4LayerStage, mode: .pipeline, hasPrivateImages: false,
                                       prefillSchedule: .oneChunkLookahead) == Plan.defaultBatchLanes)
        #expect(Plan.defaultBatchLanes(adapter: .gemma4LayerStage, mode: .pipeline, hasPrivateImages: false) == Plan.defaultBatchLanes)
        #expect(Plan.defaultBatchLanes(adapter: .gemma4LayerStage, mode: .pipeline, hasPrivateImages: true,
                                       prefillSchedule: .serial) == nil)
        // Gemma 4 tensor parallel's own lanes are its batch driver's (checked above).
        for mode in ClusterGenerationMode.allCases where mode != .pipeline && mode != .tensorParallel {
            #expect(Plan.defaultBatchLanes(adapter: .gemma4LayerStage, mode: mode, hasPrivateImages: false,
                                           prefillSchedule: .serial) == nil)
        }
        #expect(Plan.defaultBatchLanes(adapter: .gemma4LayerStage, mode: .tensorParallel, hasPrivateImages: false,
                                       prefillSchedule: .serial) == Plan.defaultBatchLanes)
        // Every other lane adapter keeps its singleton default under either schedule.
        for adapter in Plan.laneAdapters where adapter != .gemma4LayerStage {
            for schedule in ClusterPrefillSchedule.allCases {
                #expect(Plan.defaultBatchLanes(adapter: adapter, mode: .pipeline, hasPrivateImages: false,
                                               prefillSchedule: schedule) == Plan.defaultBatchLanes)
            }
        }
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
            #expect(Plan.defaultBatchLanes(adapter: adapter, mode: .tensorParallel, hasPrivateImages: false)
                == Plan.tensorParallelLaneAdapters[adapter])
        }
        for mode in ClusterGenerationMode.allCases where mode != .pipeline && mode != .tensorParallel {
            for adapter in ClusterRuntimeAdapter.allCases {
                #expect(Plan.defaultBatchLanes(adapter: adapter, mode: mode, hasPrivateImages: false) == nil)
            }
        }
        #expect(Plan.defaultBatchLanes(adapter: .mimoV26ImageCandidate, mode: .pipeline, hasPrivateImages: true) == nil)
    }
}
