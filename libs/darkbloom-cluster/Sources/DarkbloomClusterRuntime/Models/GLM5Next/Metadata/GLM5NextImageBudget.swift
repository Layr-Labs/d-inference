import Foundation
import DarkbloomClusterProtocol
import MLXLLM
import MLXVLM

/// Additive media reservation beside text state and its conservative workspace.
/// This is a conservative bound, not measured qualification. Both ranks keep
/// the encoded command; only rank 0 owns pixels, patches, features and tower work.
enum GLM5NextImageBudget {
    static let conservativeNativeScratchBytes = 11 * 1024 * 1024 * 1024 / 2
    static func bytes(configuration c: GLM5NextConfiguration, rank: Int, chunk: Int,
                      native: (Int) throws -> Int, host: (Int) throws -> Int) throws -> (native: Int, host: Int) {
        try GLM5NextClusterImagePlan.requireConfiguration(c)
        guard (0...1).contains(rank), chunk > 0 else { throw ProbeError("GLM image budget rank/chunk") }
        let mul = GLM5NextClusterImagePlan.product, add = GLM5NextClusterImagePlan.sum
        func rounded(_ bytes: Int, _ bound: (Int) throws -> Int) throws -> Int {
            let result = try bound(bytes)
            guard result >= bytes else { throw ProbeError("GLM image allocation underquote") }
            return result
        }
        let wire = try rounded(ClusterStillImages.maximumEnvelopeBytes * 16 + ClusterWorkerLimits.commandBytes * 4, host)
        if rank == 1 { return (0, wire) }
        let v = c.visionConfig, p = GLM5NextClusterImagePlan.maximumPatches
        let patch = try mul([p, 6, v.patchSize, v.patchSize, 4])
        let features = try mul([ClusterStillImages.maximumFeatures, v.outHiddenSize, 4])
        let hidden = try mul([p, v.hiddenSize, 4])
        let mlp = try mul([p, max(v.intermediateSize, v.projectionIntermediateSize), 4])
        let merged = try mul([p, v.outHiddenSize, 4])
        let scores = try mul([v.numHeads, 128, p, 4])
        let splice = try mul([chunk, c.textConfig.hiddenSize, 4])
        // Evaluated checkpoints bound layer lifetimes. Full K/V/Q, tiled scores,
        // norms, gates, residual/copy, convolution/merger and float casts coexist.
        // An extra conservative activation reserve covers native kernel scratch.
        let n = try add([mul([rounded(patch, native), 3]), mul([rounded(features, native), 4]),
            mul([rounded(hidden, native), 16]), mul([rounded(mlp, native), 8]),
            mul([rounded(merged, native), 8]), mul([rounded(scores, native), 4]),
            mul([rounded(splice, native), 4]), conservativeNativeScratchBytes])
        let h = try add([wire, rounded(128 * 1024 * 1024, host), mul([rounded(patch, host), 2])])
        return (n, h)
    }
}
