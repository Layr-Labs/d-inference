import Foundation
import MLX

/// Exact verified source descriptors; no constructor or resident arrays. The
/// caller must already own the native device and a bounded resource/lifetime
/// scope before calling prepare. Header admission alone is never that permit.
final class Gemma4RegisteredSource {
    let artifact: Gemma4ArtifactMetadata
    let plan: Gemma4LayerStagePlan
    let checkpoint: VerifiedCheckpoint
    let tensors: [String: TensorDescriptor]

    private init(artifact: Gemma4ArtifactMetadata, plan: Gemma4LayerStagePlan,
                 checkpoint: VerifiedCheckpoint, tensors: [String: TensorDescriptor]) {
        self.artifact = artifact; self.plan = plan
        self.checkpoint = checkpoint; self.tensors = tensors
    }

    static func prepare(directory: URL, artifact: Gemma4ArtifactMetadata,
                        cut: Int, check: () throws -> Void) throws -> Self {
        try check()
        let plan = try Gemma4LayerStagePlan(artifact: artifact, cut: cut)
        let checkpoint = try VerifiedCheckpoint(directory: directory,
            configurationData: artifact.originalConfiguration,
            expectedAggregateSHA256: Gemma4ArtifactMetadata.artifactAggregateSHA256,
            maximumPayloadBytes: 15_641_239_295,
            expectedManifestSHA256: Gemma4ArtifactMetadata.manifestSHA256)
        try check(); try checkpoint.requireConfiguration(artifact.originalConfiguration)
        let actual = try tensorDescriptors(checkpoint: checkpoint)
        guard actual.count == artifact.sources.count,
              Set(actual.keys) == Set(artifact.sources.map { $0.layout.canonicalName }) else {
            throw ProbeError("Registered Gemma verified source coverage differs")
        }
        for source in artifact.sources {
            let dtype = try Gemma4ForwardDType(safetensorsName: source.layout.sourceDType)
            guard let descriptor = actual[source.layout.canonicalName],
                  descriptor.file.path == source.sourceFile,
                  descriptor.offset == source.sourceOffset,
                  descriptor.shape == source.layout.shape,
                  String(describing: descriptor.dtype) == dtype.nativeSourceName,
                  descriptor.byteCount == source.layout.byteCount else {
                throw ProbeError("Registered Gemma verified source descriptor differs")
            }
        }
        try checkpoint.checkUnchanged(); try check()
        return .init(artifact: artifact, plan: plan, checkpoint: checkpoint, tensors: actual)
    }

    func selection(_ target: Gemma4ForwardTarget) throws -> [Gemma4SelectedTensor] {
        try Gemma4ForwardSelection.make(plan: plan, target: target)
    }
}
