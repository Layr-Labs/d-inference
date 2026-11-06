import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM

/// The owner's launch of a Gemma 4 tensor-parallel rank with the assistant
/// (`ClusterGemmaTensorAssistant`): the artifact's local directory, its pinned
/// manifest aggregate and the round depth. Both ranks bind the aggregate and
/// the depth into their load agreement.
public struct Gemma4TensorParallelAssistantLaunch: Equatable, Sendable {
    public let directory: URL
    public let aggregateSHA256: String
    public let depth: Int

    public init(directory: URL, aggregateSHA256: String, depth: Int) {
        self.directory = directory; self.aggregateSHA256 = aggregateSHA256; self.depth = depth
    }

    /// The assistant artifact's payload at most (the catalog's QAT 4-bit
    /// assistant is 236 MB): a larger manifest is refused before any read.
    static let maximumPayloadBytes = 1 << 30

    /// Load-agreement fields: the drafter's terms, the depth and the artifact.
    var agreementFields: [String] {
        [Gemma4TensorParallelAssistant.agreementName, "depth=\(depth)", "assistant=\(aggregateSHA256)"]
    }
}

extension Gemma4AssistantCheckpoint {
    /// The pinned artifact, verified file by file against its manifest and the
    /// expected aggregate before the model reads it, and checked unchanged
    /// after: the assistant and its payload bytes.
    static func loadVerified(_ launch: Gemma4TensorParallelAssistantLaunch,
                             check: () throws -> Void) throws -> (model: Gemma4AssistantDraftModel, payloadBytes: Int) {
        let configurationData = try BoundedProbeInput.data(launch.directory.appendingPathComponent("config.json"),
                                                           maximumBytes: 1_048_576)
        let checkpoint = try VerifiedCheckpoint(directory: launch.directory, configurationData: configurationData,
            expectedAggregateSHA256: launch.aggregateSHA256,
            maximumPayloadBytes: Gemma4TensorParallelAssistantLaunch.maximumPayloadBytes)
        try check()
        // The model reads every safetensors file in the directory: each must be a verified one.
        let present = try FileManager.default.contentsOfDirectory(at: launch.directory.resolvingSymlinksInPath(),
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "safetensors" }.map(\.lastPathComponent)
        guard !present.isEmpty, Set(present).isSubset(of: Set(checkpoint.files.keys)) else {
            throw ProbeError("Gemma assistant directory holds weights its manifest does not name")
        }
        let model = try loadModel(directory: launch.directory)
        try check()
        for file in checkpoint.files.values { try file.checkUnchanged() }
        return (model, checkpoint.files.values.reduce(0) { $0 + $1.size })
    }
}
