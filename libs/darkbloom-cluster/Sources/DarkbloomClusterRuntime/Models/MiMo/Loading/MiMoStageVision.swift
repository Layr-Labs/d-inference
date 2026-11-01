import Foundation
import DarkbloomClusterProtocol
import MLX
import MLXLLM
import MLXNN
import MLXVLM

final class MiMoStageVisionLoadFailure: Error, @unchecked Sendable {
    let cause: Error
    private var retained: Module?
    init(cause: Error, retained: Module) { self.cause = cause;self.retained = retained }
    func releaseAfterCheckedDrain() { retained = nil }
}

/// Rank-local tower custody. The enclosing resident executor owns all calls.
/// Source/checkpoint validation precedes construction; no provider MLX work.
final class MiMoStageVision {
    let tower: MiMoV26VisionTower
    let configuration: MiMoV26Configuration
    let storageBytes: Int

    struct Inventory {
        let descriptors: [(name:String, descriptor:TensorDescriptor)]
        let storageBytes, allocationBytes, largestTensorBytes: Int
        let fingerprint: String
    }
    static func inventory(_ source: MiMoResidentSource) throws -> Inventory {
        let c = try JSONDecoder().decode(MiMoV26Configuration.self,from:source.plan.originalConfiguration)
        guard let vision = c.vision else { throw ProbeError("MiMo vision configuration missing") }
        var expected = try MiMoV26VisionTower.expectedTensorShapes(configuration:vision)
        if let patch = expected["visual.patch_embed.proj.weight"] {
            expected["visual.patch_embed.proj.weight"] = [vision.hiddenSize,
                try QwenLongPrefillCheckedBytes.product(Array(patch.dropFirst()))]
        }
        var descriptors:[(name:String,descriptor:TensorDescriptor)] = []
        for (name,shape) in expected.sorted(by: { $0.key < $1.key }) {
            let sourceName = "vision_tower." + name.dropFirst("visual.".count)
            guard let d = source.mediaDescriptors[sourceName], d.shape == shape, d.dtype == .bfloat16 else {
                throw ProbeError("MiMo vision descriptor/layout differs: \(sourceName)")
            }
            descriptors.append((name,d))
        }
        guard Set(source.mediaDescriptors.keys) == Set(expected.keys.map { "vision_tower." + $0.dropFirst("visual.".count) }) else {
            throw ProbeError("Unmapped MiMo vision tensors")
        }
        let bytes = try QwenLongPrefillCheckedBytes.sum(descriptors.map { $0.descriptor.byteCount })
        let allocations = try QwenLongPrefillCheckedBytes.sum(descriptors.map {
            try Memory.allocationFootprintUpperBound(byteCount:$0.descriptor.byteCount)
        })
        guard descriptors.count == ClusterMiMoImageCandidate.visionTensorCount,
              bytes == ClusterMiMoImageCandidate.visionTensorBytes,
              descriptors.map({ $0.descriptor.byteCount }).max() == ClusterMiMoImageCandidate.largestVisionTensorBytes else {
            throw ProbeError("MiMo candidate vision inventory storage differs from pinned metadata")
        }
        let identity = try descriptors.map { "\($0.name)|\(try $0.descriptor.storedDTypeName)|\($0.descriptor.shape)|\($0.descriptor.byteCount)" }
        let fingerprint = sha256(Data((source.checkpoint.aggregate + "|" + identity.joined(separator:"\n")).utf8))
        guard fingerprint == ClusterMiMoImageCandidate.visionStorageCommitmentSHA256 else {
            throw ProbeError("MiMo candidate vision inventory commitment differs")
        }
        return .init(descriptors:descriptors,storageBytes:bytes,allocationBytes:allocations,
            largestTensorBytes:descriptors.map { $0.descriptor.byteCount }.max() ?? 0,fingerprint:fingerprint)
    }
    init(source: MiMoResidentSource, inventory: Inventory, check: () throws -> Void) throws {
        configuration = try JSONDecoder().decode(MiMoV26Configuration.self,from:source.plan.originalConfiguration)
        storageBytes = inventory.storageBytes
        var remaining = inventory.allocationBytes
        func gate() throws {
            try check();try source.checkpoint.checkUnchanged()
            let host = inventory.largestTensorBytes
            let scratch = CheckpointAlignedReadPlan.maximumScratchAllocationBytes
            let needed = try QwenLongPrefillCheckedBytes.sum([remaining,host,host,scratch,
                QwenDenseStageLoadPolicy.loadingHeadroomBytes,ClusterMiMoImageCandidate.activationFloorBytes])
            let native = try QwenLongPrefillCheckedBytes.sum([Memory.activeMemory,Memory.cacheMemory,
                remaining,host,host,scratch,QwenDenseStageLoadPolicy.allocatorHeadroomBytes,ClusterMiMoImageCandidate.activationFloorBytes])
            let os = try QwenDenseStageLoadResources.observeOS()
            guard try QwenDenseStageLoadWatch("MiMo vision LOAD").admits(os,bytes:max(
                QwenDenseStageLoadPolicy.minimumAdmissibleBytes,needed)), Memory.memoryLimit >= native else {
                throw ProbeError("MiMo vision exceeds native/host LOAD limits")
            }
        }
        try gate()
        let loadedTower = try MiMoV26VisionTower(configuration:configuration.vision!)
        tower = loadedTower
        var cursor = 0
        do { try loadedTower.loadNativeWeightsSerial(flattenedPatchStorage:true,read: { name, shape in
            try gate()
            guard cursor < inventory.descriptors.count, inventory.descriptors[cursor].name == name else {
                throw ProbeError("MiMo serial vision load changed order")
            }
            let d = inventory.descriptors[cursor].descriptor
            let read = try d.read(.all)
            guard read.copiedBytes == d.byteCount, read.readAccounting?.selectedBytes == d.byteCount else {
                throw ProbeError("MiMo vision payload custody is incomplete")
            }
            let array = read.array
            eval(array);Stream.gpu.synchronize();try check()
            guard array.shape == shape, array.dtype == .bfloat16, array.nbytes == d.byteCount,
                  let info = try array.evaluatedBufferInfo(), info.isUnique, info.dataOffset == 0,
                  info.isRowContiguous, info.dataElements == array.size,
                  info.allocatedBytes >= array.nbytes,
                  info.allocatedBytes <= (try Memory.allocationFootprintUpperBound(byteCount:array.nbytes)) else {
                throw ProbeError("MiMo vision tensor is not an owned exact source allocation")
            }
            remaining -= try Memory.allocationFootprintUpperBound(byteCount:d.byteCount)
            cursor += 1
            return array
        },checkpoint: { arrays in eval(arrays);Stream.gpu.synchronize();try check() })
        guard remaining == 0, cursor == inventory.descriptors.count, loadedTower.trainableParameters().flattened().isEmpty else {
            throw ProbeError("MiMo vision LOAD did not finish")
        }
        try source.checkpoint.checkUnchanged();try check()
        } catch { throw MiMoStageVisionLoadFailure(cause:error,retained:loadedTower) }
    }
}

/// CPU quote from the same SDK geometry/workspace implementation that runs.
/// Conservative coexistent host/native charge; never changes allocator limits.
struct MiMoStageImageBudget {
    let inspections: [MiMoV26ClusterImagePlan.Inspection]
    let reservedBytes: Int
    static func derive(_ media: ClusterMiMoImages, prompt: [Int], configuration: MiMoV26Configuration,
                       chunkSize: Int, rank: Int, bound: (Int) throws -> Int) throws -> Self {
        try media.validate(prompt:prompt)
        guard (0...1).contains(rank), chunkSize > 0 else { throw ProbeError("MiMo image rank/chunk") }
        let add = QwenLongPrefillCheckedBytes.sum, mul = QwenLongPrefillCheckedBytes.product
        func checkedBound(_ bytes: Int) throws -> Int {
            let result = try bound(bytes)
            guard bytes > 0,result >= bytes else { throw ProbeError("MiMo image allocator bound underquotes storage") }
            return result
        }
        var inspections:[MiMoV26ClusterImagePlan.Inspection] = []
        for image in media.images {
            let i = try MiMoV26ClusterImagePlan.inspectPNG(image.png,configuration:configuration,
                maximumEncodedBytes:ClusterMiMoImages.maximumEncodedBytes,maximumPixels:ClusterMiMoImages.maximumPixels)
            guard i.width == image.width, i.height == image.height, i.geometry.mediaTokens == image.tokenCount,
                  i.geometry.patchCount <= ClusterMiMoImageCandidate.maximumPreparedPatches else {
                throw ProbeError("MiMo wire dimensions/span differ from actual image geometry")
            }
            inspections.append(i)
        }
        // Both ranks retain bounded command/decode/base64 copies. Rank 1 only
        // inspects headers and never owns decoded pixels/patches/features.
        let transport = try add([try mul([media.encodedBytes,12]),ClusterWorkerLimits.commandBytes,ClusterWorkerLimits.commandBytes])
        if rank == 1 { return .init(inspections:inspections,reservedBytes:transport) }
        var featureBytes = 0, peak = 0
        for i in inspections {
            let features = try mul([i.geometry.mediaTokens,configuration.hiddenSize,2])
            let patches = try mul([i.geometry.patchElementCount,4])
            featureBytes = try add([featureBytes,try checkedBound(features),try checkedBound(features)])
            peak = max(peak,try add([i.decodeBytes,i.pixelWorkingBytes,patches,
                try checkedBound(patches),i.towerWorkingBytes]))
        }
        let splice = try mul([try checkedBound(mul([chunkSize,configuration.hiddenSize,2])),3])
        let total = try add([transport,featureBytes,peak,splice])
        guard total <= ClusterMiMoImageCandidate.activationFloorBytes else {
            throw ProbeError("MiMo SDK media working quote exceeds the candidate activation envelope")
        }
        return .init(inspections:inspections,reservedBytes:total)
    }
}

/// Request-owned evaluated feature rows. Only rank 0 creates this object.
final class MiMoStageImageFeatures {
    let media: ClusterMiMoImages
    private var features: [MLXArray] = []
    private var pendingRoots: [MLXArray] = []
    private var prepared = false
    init(media: ClusterMiMoImages) { self.media = media }
    func prepare(owner: MiMoStageVision, check: () throws -> Void) throws {
        guard !prepared, features.isEmpty else { throw ProbeError("MiMo image features are one-shot") }
        let settings = try MiMoV26ClusterImagePlan.settings(configuration:owner.configuration)
        for image in media.images {
            try autoreleasepool {
                try check()
                let inspection = try MiMoV26ClusterImagePlan.inspectPNG(image.png,configuration:owner.configuration,
                    maximumEncodedBytes:ClusterMiMoImages.maximumEncodedBytes,maximumPixels:ClusterMiMoImages.maximumPixels)
                let decoded = try MiMoV26EncodedVisualDecoder.image(image.png,limits:.init(
                    maximumPixels:ClusterMiMoImages.maximumPixels,maximumWorkingBytes:inspection.decodeBytes,
                    maximumSourceFrames:1,maximumSampledFrames:1,maximumEncodedBytes:ClusterMiMoImages.maximumEncodedBytes))
                try check()
                guard decoded.width == image.width, decoded.height == image.height else { throw ProbeError("MiMo decoded geometry changed") }
                let pixels = try MiMoV26Pixels.image(decoded,settings:settings,limits:.init(
                    maximumInputElements:3*image.width*image.height,
                    maximumOutputElements:inspection.geometry.patchElementCount,
                    maximumWorkingBytes:inspection.pixelWorkingBytes))
                guard pixels.geometry == inspection.geometry else { throw ProbeError("MiMo pixel preparation geometry changed") }
                let patches = MLXArray(pixels.patchValues).reshaped(pixels.geometry.patchCount,pixels.geometry.patchVectorSize)
                pendingRoots = [patches]
                let output = try owner.tower.forwardBounded(patches:patches,grids:[.init(
                    temporal:pixels.geometry.gridT,height:pixels.geometry.gridH,width:pixels.geometry.gridW)],
                    limits:.init(maximumPatches:pixels.geometry.patchCount,maximumAttentionScoreElements:Int.max),
                    checkpoint: { [self] roots in pendingRoots = roots;eval(features+pendingRoots);Stream.gpu.synchronize();try check() })
                eval(output);Stream.gpu.synchronize();try check()
                guard output.shape == [image.tokenCount,owner.configuration.hiddenSize],output.dtype == .bfloat16 else {
                    throw ProbeError("MiMo image features differ from source geometry/dtype")
                }
                features.append(output);pendingRoots = []
            }
        }
        prepared = true
    }
    func embeddings(tokens: [Int], offset: Int, model: MiMoV26TextModel) throws -> MLXArray {
        guard prepared,features.count == media.images.count else { throw ProbeError("MiMo image features are incomplete") }
        let base = try model.embedForMedia(tokens)
        var pieces:[MLXArray] = [], cursor = 0
        for (image,feature) in zip(media.images,features) {
            let start = max(offset,image.tokenOffset), end = min(offset+tokens.count,image.tokenOffset+image.tokenCount)
            guard start < end else { continue }
            let local = start-offset
            if cursor < local { pieces.append(base[0...,cursor..<local,0...]) }
            pieces.append(feature[(start-image.tokenOffset)..<(end-image.tokenOffset)].expandedDimensions(axis:0))
            cursor = end-offset
        }
        if cursor < tokens.count { pieces.append(base[0...,cursor..<tokens.count,0...]) }
        return pieces.count == 1 ? pieces[0] : concatenated(pieces,axis:1)
    }
}
