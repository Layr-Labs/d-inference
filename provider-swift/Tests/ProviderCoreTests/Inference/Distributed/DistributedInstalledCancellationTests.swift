import DarkbloomClusterProtocol
import Testing
@testable import ProviderCore

struct DistributedInstalledCancellationTests {
    @Test func cancellationIsolationMatchesOnlyEligibleModesAndLanes() {
        typealias Plan = DistributedInstalledPlan
        let pipeline: Set<ClusterRuntimeAdapter> = [.qwen35Dense, .qwen35RoutedExperts, .qwen35PrismHadamard, .gemma4LayerStage, .gptossLayerStage, .nemotronH, .mimoV26LayerStage]
        for adapter in ClusterRuntimeAdapter.allCases {
            for mode in ClusterGenerationMode.allCases {
                for images in [false, true] {
                    for lanes in [0, 1, 2, 4, 8, 9] {
                        let validLanes = (2...8).contains(lanes)
                        let existingGLM = mode == .tensorParallel && adapter == .glm5NextLayerStage
                        let qwenPipeline = mode == .pipeline && pipeline.contains(adapter) && !images
                        #expect(Plan.lanesRetireAlone(adapter: adapter, mode: mode,
                            hasPrivateImages: images, lanes: lanes) == (validLanes && (existingGLM || qwenPipeline)))
                    }
                }
            }
        }
        #expect(Plan.defaultBatchLanes == 1)
        #expect(Plan.tensorParallelBatchLanes == 8)
    }
}
