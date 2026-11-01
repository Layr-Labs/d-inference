import Foundation
import DarkbloomClusterProtocol
@testable import InstalledContract

extension InstalledSessionCheck {
    /// Immutable metadata from the actual 2026-10-23 Qwen3.6 16K pair checks.
    /// No payload, model or GPU is used here. A short passing run never erases
    /// a genuine divergent shape, and a reversed rank order is distinct.
    static func tensorQualificationShapes(_ f: InstalledFixture) throws {
        let negative = try ClusterPairQualificationRecord.decodeLines(Self.tensorFailure)[0]
        let positive = try ClusterPairQualificationRecord.decodeLines(Self.tensorPass)[0]
        try require(negative.isConsistent && !negative.passed && negative.cuts.isEmpty
            && negative.comparisons.map(\.gapInULPs) == [7, 5]
            && negative.comparisons.allSatisfy { $0.nearTieThresholdULPs == 4 }, "actual negative metadata changed")
        try require(positive.isConsistent && positive.passed && positive.cuts.isEmpty, "actual reverse-order pass changed")
        let m3 = ClusterChipClass(chipName: "Apple M3 Ultra")!, m5 = ClusterChipClass(chipName: "Apple M5 Max")!
        let model = negative.runtimeModelID
        let onlyFailure = ClusterPairServingDecisions(records: [negative])
        try require(onlyFailure.ignored == 0 && onlyFailure.withheld[model]?.contains("no layer cuts") == true,
            "TP-only divergence must construct a bounded withholding reason without a layer cut")
        let mixed = ClusterPairServingDecisions(records: [negative, positive])
        for decisions in [onlyFailure, mixed] {
            try require(!ClusterPairServingGrants.plannable([m3, m5], cuts: [], mode: .tensorParallel,
                runtimeModelID: model, artifactSHA256: negative.artifactSHA256, decisions: decisions), "failed TP order remains plannable")
            try require(ClusterPairServingGrants.plannable([m5, m3], cuts: [], mode: .tensorParallel,
                runtimeModelID: model, artifactSHA256: negative.artifactSHA256, decisions: decisions), "reverse TP order was overblocked")
            try require(ClusterPairServingGrants.startRefusal([m3, m5], cuts: [], mode: .tensorParallel,
                runtimeModelID: model, publicModelID: "fixture/qwen36", artifactSHA256: negative.artifactSHA256,
                decisions: decisions) != nil, "failed TP order has no start refusal")
            try require(ClusterPairServingGrants.startRefusal([m5, m3], cuts: [], mode: .tensorParallel,
                runtimeModelID: model, publicModelID: "fixture/qwen36", artifactSHA256: negative.artifactSHA256,
                decisions: decisions) == nil, "reverse TP order was refused")
        }
        let fixture = try InstalledFixture.make(root: f.root.appendingPathComponent("tp-negative-shape"),
            probe: f.probe, owner: f.owner, worker: f.worker, generationMode: ClusterGenerationMode.tensorParallel.rawValue,
            advertisedModes: [.pipeline, .tensorParallel, .pipelinePrefillTensorDecode],
            registered: (model, "registered_qwen36_35b_a3b_greedy_generation_v1", "fixture/qwen36"), adapter: .qwen35RoutedExperts)
        // Exercise the actual installed rank guard using a real saved Plan.
        // Its capability has a nonempty partition cut: passing that cut to the
        // guard instead of the mode's [] shape used to miss the negative record.
        for rank in 0...1 {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.configuration)) as! [String: Any]
            object["role"] = rank == 0 ? "leader" : "follower"
            object["memberID"] = fixture.configuration.peers[rank].id
            let data = try JSONSerialization.data(withJSONObject: object)
            let config = try ClusterConfigurationCodec.decode(data, capability: fixture.capability,
                capabilitySHA256: fixture.configuration.capabilitySHA256)
            let plan = try DistributedInstalledPlan(saved: .init(configuration: config, capability: fixture.capability), paths: fixture.paths)
            try require(!plan.partition.stages.dropLast().isEmpty, "fixture lost its bookkeeping layer cut")
            try rejected { try plan.requireLocalRankGranted(chipClass: rank == 0 ? m3 : m5, decisions: mixed) }
            try plan.requireLocalRankGranted(chipClass: rank == 0 ? m5 : m3, decisions: mixed)
            // Pipeline and the pipeline-prefill hybrid retain their real layer
            // cut. A negative tensor family never becomes a pipeline failure.
            for mode in [ClusterGenerationMode.pipeline, .pipelinePrefillTensorDecode] {
                object["generationMode"] = mode.rawValue
                let config = try ClusterConfigurationCodec.decode(JSONSerialization.data(withJSONObject: object),
                    capability: fixture.capability, capabilitySHA256: fixture.configuration.capabilitySHA256)
                let plan = try DistributedInstalledPlan(saved: .init(configuration: config, capability: fixture.capability), paths: fixture.paths)
                try plan.requireLocalRankGranted(chipClass: rank == 0 ? m3 : m5, decisions: mixed)
            }
        }
        print("Installed TP qualification: actual 16K negative blocks both failed rank-shapes, reverse order/pipeline survive, TP-only withholding constructs safely")
    }

    private static let tensorFailure = #"""
{"artifactSHA256":"d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed","chunkTokens":512,"comparisons":[{"allowed":["cut","schedule"],"firstDivergenceIndex":10,"gapInULPs":7,"nearTieThresholdULPs":4,"referenceChip":"Apple M5 Max","verdict":"diverged"},{"allowed":["cut","schedule"],"firstDivergenceIndex":10,"gapInULPs":5,"nearTieThresholdULPs":4,"referenceChip":"Apple M3 Ultra","verdict":"diverged"}],"cuts":[],"generationMode":"tensor_parallel_v1","outputTokens":128,"pairReportCreatedUTC":"2026-10-23T09:43:38Z","pairReportSHA256":"542810cd3a659bf507f9e15b407a851cf30e664a52b6e0472087ce670c967d56","passed":false,"prefillSchedule":"one_chunk_lookahead_v1","producer":"darkbloom-cluster-pair-check record","promptTokens":16384,"ranks":[{"chip":"Apple M3 Ultra","operatingSystem":"27.2","rank":0},{"chip":"Apple M5 Max","operatingSystem":"27.0","rank":1}],"runtimeModelID":"registered_qwen36_35b_a3b","schema":"darkbloom_cluster_pair_qualification_v1","tensorParallelLayout":"plan=qwen_moe_heads_and_expert_channels_v1;partials=float32;shares=equal;reduction=sealed_all_gather_sum_v1","transport":"jaccl"}
"""#
    private static let tensorPass = #"""
{"artifactSHA256":"d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed","chunkTokens":512,"comparisons":[{"allowed":["cut","schedule"],"firstDivergenceIndex":56,"gapInULPs":0,"nearTieThresholdULPs":4,"referenceChip":"Apple M5 Max","verdict":"divergedAtNearTie"},{"allowed":["cut","schedule"],"firstDivergenceIndex":25,"gapInULPs":0,"nearTieThresholdULPs":4,"referenceChip":"Apple M3 Ultra","verdict":"divergedAtNearTie"}],"cuts":[],"generationMode":"tensor_parallel_v1","outputTokens":128,"pairReportCreatedUTC":"2026-10-23T09:42:54Z","pairReportSHA256":"6c96c20ed7f464cb328d07a5be8529407a69be8de346a380d436063e145638d9","passed":true,"prefillSchedule":"one_chunk_lookahead_v1","producer":"darkbloom-cluster-pair-check record","promptTokens":16384,"ranks":[{"chip":"Apple M5 Max","operatingSystem":"27.0","rank":0},{"chip":"Apple M3 Ultra","operatingSystem":"27.2","rank":1}],"runtimeModelID":"registered_qwen36_35b_a3b","schema":"darkbloom_cluster_pair_qualification_v1","tensorParallelLayout":"plan=qwen_moe_heads_and_expert_channels_v1;partials=float32;shares=equal;reduction=sealed_all_gather_sum_v1","transport":"jaccl"}
"""#
}
