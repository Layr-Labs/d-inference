import Foundation
import DarkbloomClusterProtocol
import MLX
import MLXLLM
import MLXVLM

/// The serial rank-0 tower and the text stage share one verified loader and
/// construction-root owner. Throws leave all aliases with that resident.
final class GLM5NextStageVision {
    let tower: GLM5NextVisionTower
    let configuration: GLM5NextConfiguration
    init(loader: GLM5NextArtifactLoader, roots: GLM5NextArtifactLoadRoots,
         beforeRead: (String, Int) throws -> Void, check: () throws -> Void) throws {
        configuration = loader.configuration
        try GLM5NextClusterImagePlan.requireConfiguration(configuration)
        try check()
        tower = try GLM5NextVisionTower(configuration: configuration.visionConfig)
        roots.retainOwner(tower)
        let expected = GLM5NextVisionTower.expectedTensorShapes(configuration: configuration.visionConfig)
        let names = Set(expected.keys.map { "model.visual." + $0 })
        guard names == Set(loader.inventory.entries(in: .vision).map { $0.tensor.name }) else {
            throw ProbeError("GLM vision inventory has unmapped source tensors")
        }
        let dtype: DType
        switch configuration.textConfig.dtype {
        case "bfloat16": dtype = .bfloat16
        case "float32": dtype = .float32
        default: throw ProbeError("GLM cluster vision dtype is unsupported")
        }
        var weights: [String: MLXArray] = [:]
        for name in names.sorted() {
            guard let entry = loader.inventory.entries[name],
                  entry.tensor.shape == expected[String(name.dropFirst("model.visual.".count))] else {
                throw ProbeError("GLM vision source shape differs")
            }
            try check(); try beforeRead(name, entry.bytes)
            let value = try loader.tensor(name)
            guard value.dtype == dtype else { throw ProbeError("GLM vision source dtype differs") }
            weights[name] = value
        }
        try tower.loadNativeWeights(weights, dtype: dtype)
        tower.freeze()
        try roots.evaluate(tower.parameters().flattened().map(\.1))
        Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check()
        try loader.requireConsumed(.vision)
    }
}

/// Request-owned features, retained even after a failed evaluation until the
/// session's checked drain. No global media cache or raw-media telemetry.
final class GLM5NextStageImageFeatures {
    let media: ClusterStillImages
    private let owner: GLM5NextStageVision
    private var features: [MLXArray] = []
    private var pending: [MLXArray] = []
    private var started = false
    init(media: ClusterStillImages, owner: GLM5NextStageVision) { self.media = media; self.owner = owner }
    func prepare(check: () throws -> Void) throws {
        guard !started else { throw ProbeError("GLM image preparation is single-use") }
        started = true
        let processor = GLM5NextProcessor(imageConfiguration: try GLM5NextClusterImagePlan.processorConfiguration(owner.configuration))
        for image in media.images {
            try check()
            let i = try GLM5NextClusterImagePlan.inspectPNG(image.png, configuration: owner.configuration)
            let decoded = try GLM5NextClusterImagePlan.decodePNG(image.png, inspection: i, configuration: owner.configuration)
            try check()
            let prepared = try processor.prepareImage(decoded, checkpoint: { [self] arrays in
                pending = arrays; try check()
            })
            pending = [prepared.patches]
            guard prepared.grid == i.resize.grid, prepared.patches.nbytes == i.patchBytes else {
                throw ProbeError("GLM prepared image differs from admission")
            }
            let value = try owner.tower.forward(patches: prepared.patches, grids: [prepared.grid],
                limits: .init(maximumPatches: GLM5NextClusterImagePlan.maximumPatches,
                    maximumFramePatches: GLM5NextClusterImagePlan.maximumPatches,
                    maximumQueryTokens: 128, maximumScoreElements: 128 * GLM5NextClusterImagePlan.maximumPatches * owner.configuration.visionConfig.numHeads,
                    attention: .tiled), checkpoint: { [self] arrays in
                    pending = arrays; eval(pending + features); Stream.gpu.synchronize(); try check()
                })
            pending.append(value); eval(value); Stream.gpu.synchronize(); try check()
            guard value.shape == [image.tokenCount, owner.configuration.textConfig.hiddenSize],
                  String(describing: value.dtype) == owner.configuration.textConfig.dtype else {
                throw ProbeError("GLM image features differ from admitted span/dtype")
            }
            features.append(value); pending = []
        }
    }
    func embeddings(tokens: [Int], offset: Int, model: GLM5NextTextStage) throws -> MLXArray {
        guard features.count == media.images.count, let embedding = model.embedding else {
            throw ProbeError("GLM image feature custody is incomplete")
        }
        let input = MLXArray(tokens.map(Int32.init), [1, tokens.count])
        pending = [input]
        let base = embedding(input)
        pending.append(base)
        var pieces: [MLXArray] = [], cursor = 0
        for (image, value) in zip(media.images, features) {
            let start = max(offset, image.tokenOffset), end = min(offset + tokens.count, image.tokenOffset + image.tokenCount)
            guard start < end else { continue }
            if cursor < start - offset { pieces.append(base[0..., cursor..<start-offset, 0...]) }
            pieces.append(value[(start-image.tokenOffset)..<(end-image.tokenOffset)].expandedDimensions(axis: 0))
            cursor = end - offset
        }
        if cursor < tokens.count { pieces.append(base[0..., cursor..<tokens.count, 0...]) }
        let result = pieces.count == 1 ? pieces[0] : concatenated(pieces, axis: 1)
        pending = [base, result]
        return result
    }
}
