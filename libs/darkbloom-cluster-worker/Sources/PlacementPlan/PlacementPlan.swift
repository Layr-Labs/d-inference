import DarkbloomClusterRuntime
import Foundation

/// `darkbloom-cluster-plan`: what this Mac detects about itself, what an
/// artifact is made of, and how a model is divided between devices. It reads
/// system counters and tensor headers only: no model load, no GPU work, no
/// collective, no network. The one exception is `index`, which runs about a
/// second of GPU work with no model and is used only under the GPU lane.
@main enum PlacementPlan {
    static func main() {
        do {
            let output = try ClusterPlacementTool.run(Array(CommandLine.arguments.dropFirst()),
                                                      sampleDevice: ClusterDeviceProfileSampler.sample,
                                                      measureIndex: { try ClusterDeviceIndexBenchmark.measure() })
            FileHandle.standardOutput.write(Data((output + "\n").utf8))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
