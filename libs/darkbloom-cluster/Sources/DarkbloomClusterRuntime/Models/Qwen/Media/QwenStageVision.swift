import Foundation
import MLX
import MLXNN
import MLXVLM

/// Descriptor-only identity of the rank-zero tower. Every file remains pinned
/// by the same verified checkpoint as the admitted text stage/shards.
struct QwenStageVisionInventory {
    let configuration: Qwen35Configuration
    let processor: Qwen3VLMediaProcessor
    let artifactSHA256, configurationSHA256, processorSHA256: String
    let processorConfiguration: Data
    let descriptors: [(name: String, descriptor: TensorDescriptor)]
    let storageDType: DType
    let featureDType: DType
    let storageBytes, allocationBytes, largestTensorBytes: Int
    let fingerprint: String

    var mediaIdentity: QwenMediaModelIdentity {
        .init(artifactSHA256: artifactSHA256, configurationSHA256: configurationSHA256,
            processorSHA256: processorSHA256, configuration: configuration, featureDType: featureDType)
    }

    init(source: QwenResidentLocalSource, configurationData: Data,
         specification: QwenDenseRegisteredSpecification) throws {
        let expectedBytes: Int
        switch specification.model {
        case .qwen35NineB, .ternaryBonsai2NineB: expectedBytes = 912_020_960
        case .qwen38TwentySevenB, .ternaryBonsai2TwentySevenB: expectedBytes = 921_460_192
        case .qwen35ThirtyFiveBA3B, .qwen36ThirtyFiveBA3B: expectedBytes = 893_142_496
        case .nemotron35Lightning: throw ProbeError("Registered Lightning has no Qwen vision tower")
        }
        let checkpoint = source.payload.checkpoint
        guard source.metadata.profile.model == specification.model,
            checkpoint.aggregate == specification.artifactSHA256,
            checkpoint.configurationSHA256 == specification.configurationSHA256,
            checkpoint.verifiedManifestSHA256 == specification.manifestSHA256,
            sha256(configurationData) == specification.configurationSHA256 else {
            throw ProbeError("Qwen vision source differs from the exact admitted artifact")
        }
        try checkpoint.requireConfiguration(configurationData)
        artifactSHA256 = checkpoint.aggregate
        configurationSHA256 = specification.configurationSHA256
        configuration = try JSONDecoder().decode(Qwen35Configuration.self, from: configurationData)
        let expected = try Qwen35VisionTower.expectedTensorShapes(configuration: configuration)
        guard expected.count == 333, configuration.visionConfiguration.depth == 27,
            configuration.visionConfiguration.hiddenSize == 1152,
            configuration.visionConfiguration.numHeads == 16,
            configuration.visionConfiguration.patchSize == 16,
            configuration.visionConfiguration.temporalPatchSize == 2,
            configuration.visionConfiguration.spatialMergeSize == 2 else {
            throw ProbeError("Qwen vision geometry differs from the registered family")
        }
        // The original Prism wrapper emits F16 features before the language
        // embedding splice promotes them to F32. Affine Qwen is native BF16.
        storageDType = specification.model.pack == .prismHadamard ? .float16 : .bfloat16
        featureDType = storageDType
        let indexed = try tensorDescriptors(checkpoint: checkpoint,
            scope: .init(acceptsUInt8: specification.unownedUInt8Tensors))
        var canonical: [String: TensorDescriptor] = [:]
        for (name, descriptor) in indexed {
            guard let key = Qwen35VisionTower.canonicalWeightName(name) else { continue }
            guard canonical[key] == nil else { throw ProbeError("Duplicate Qwen vision source name") }
            canonical[key] = descriptor
        }
        guard Set(canonical.keys) == Set(expected.keys) else {
            throw ProbeError("Missing or unmapped Qwen vision tensors")
        }
        var ordered: [(name: String, descriptor: TensorDescriptor)] = []
        for (name, shape) in expected.sorted(by: { $0.key < $1.key }) {
            guard let descriptor = canonical[name], descriptor.shape == shape,
                descriptor.dtype == storageDType,
                descriptor.byteCount == (try QwenLongPrefillCheckedBytes.product(shape + [storageDType.size])) else {
                throw ProbeError("Qwen vision source shape/dtype differs from its registered layout")
            }
            ordered.append((name, descriptor))
        }
        descriptors = ordered
        storageBytes = try QwenLongPrefillCheckedBytes.sum(ordered.map { $0.descriptor.byteCount })
        if specification.model == .qwen38TwentySevenB {
            // Placement and native LOAD use the same exact inventory and
            // per-array allocator policy; neither relies on observed residency.
            let budget = try QwenVisionResidentBudget(configurationSHA256: configurationSHA256,
                tensors: ordered.map { .init(name: $0.name, shape: $0.descriptor.shape,
                    sourceDType: "BF16", byteCount: $0.descriptor.byteCount) },
                allocationBound: Memory.allocationFootprintUpperBound(byteCount:))
            allocationBytes = budget.allocationBytes
        } else {
            allocationBytes = try QwenLongPrefillCheckedBytes.sum(ordered.map {
                try Memory.allocationFootprintUpperBound(byteCount: $0.descriptor.byteCount)
            })
        }
        largestTensorBytes = ordered.map { $0.descriptor.byteCount }.max() ?? 0
        guard storageBytes == expectedBytes else { throw ProbeError("Qwen visual storage differs from the pinned byte total") }
        func configurationFile(_ name: String) throws -> Data? {
            guard let file = checkpoint.files[name] else { return nil }
            guard file.size > 0, file.size <= 1_048_576 else { throw ProbeError("Qwen processor configuration exceeds its bound") }
            return try file.data(offset: 0, count: file.size)
        }
        let resolved = try Qwen3VLMediaProcessor.resolvedConfiguration(
            preprocessor: configurationFile("preprocessor_config.json"),
            processor: configurationFile("processor_config.json"))
        processorConfiguration = resolved
        processor = try Qwen3VLMediaProcessor(modelConfiguration: configurationData, processorConfiguration: resolved)
        guard processor.configuration.patchSize == 16, processor.configuration.mergeSize == 2,
            processor.configuration.temporalPatchSize == 2 else {
            throw ProbeError("Qwen processor and registered tower geometry disagree")
        }
        processorSHA256 = sha256(resolved)
        let records = try ordered.map {
            "\($0.name)|\(try $0.descriptor.storedDTypeName)|\($0.descriptor.shape)|\($0.descriptor.byteCount)"
        }
        fingerprint = sha256(Data((["qwen-vision-load-v1", checkpoint.aggregate,
            specification.configurationSHA256, processorSHA256, Qwen3VLMediaProcessor.policyID]
            + records).joined(separator: "\n").utf8))
        try checkpoint.checkUnchanged()
    }
}

final class QwenStageVisionLoadFailure: Error, @unchecked Sendable {
    let cause: Error
    private var retained: Module?
    init(cause: Error, retained: Module) { self.cause = cause; self.retained = retained }
    func releaseAfterCheckedDrain() { retained = nil }
}

/// Executor-owned tower with serial verified loading and explicit failed-load
/// custody. Native LOAD and request allowances must also include this inventory.
final class QwenStageVision {
    let tower: Qwen35VisionTower
    let inventory: QwenStageVisionInventory

    init(source: QwenResidentLocalSource, inventory: QwenStageVisionInventory,
         remainingResidentAllowanceBytes: Int, check: () throws -> Void) throws {
        guard remainingResidentAllowanceBytes >= 0 else { throw ProbeError("Negative Qwen resident LOAD allowance") }
        self.inventory = inventory
        let checkpoint = source.payload.checkpoint
        let watch = QwenDenseStageLoadWatch("Qwen vision LOAD")
        var remaining = inventory.allocationBytes
        func gate() throws {
            try check(); try checkpoint.checkUnchanged()
            let host = inventory.largestTensorBytes
            let scratch = CheckpointAlignedReadPlan.maximumScratchAllocationBytes
            let future = try QwenLongPrefillCheckedBytes.sum([remaining, host, host, scratch,
                remainingResidentAllowanceBytes])
            let needed = try QwenLongPrefillCheckedBytes.sum([future, QwenDenseStageLoadPolicy.loadingHeadroomBytes])
            let native = try QwenLongPrefillCheckedBytes.sum([Memory.activeMemory, Memory.cacheMemory,
                future, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
            let os = try QwenDenseStageLoadResources.observeOS()
            guard try watch.admits(os, bytes: needed), Memory.memoryLimit >= native else {
                throw ProbeError("Qwen vision exceeds native/host LOAD limits")
            }
        }
        try gate()
        let loaded = try Qwen35VisionTower(configuration: inventory.configuration, textDType: inventory.featureDType)
        tower = loaded
        var cursor = 0
        do {
            try checkpoint.bypassTensorPayloadCache()
            try loaded.loadNativeWeightsSerial(expectedDType: inventory.storageDType, read: { name, shape in
                try gate()
                guard cursor < inventory.descriptors.count, inventory.descriptors[cursor].name == name else {
                    throw ProbeError("Qwen vision serial read order changed")
                }
                let descriptor = inventory.descriptors[cursor].descriptor
                let result = try descriptor.read(.all)
                guard result.copiedBytes == descriptor.byteCount,
                    result.readAccounting?.selectedBytes == descriptor.byteCount else {
                    throw ProbeError("Qwen vision payload custody is incomplete")
                }
                let array = result.array
                eval(array); Stream.gpu.synchronize(); try check()
                guard array.shape == shape, array.dtype == inventory.storageDType,
                    array.nbytes == descriptor.byteCount,
                    let info = try array.evaluatedBufferInfo(), info.isUnique, info.dataOffset == 0,
                    info.isRowContiguous, info.dataElements == array.size,
                    info.allocatedBytes >= array.nbytes,
                    info.allocatedBytes <= (try Memory.allocationFootprintUpperBound(byteCount: array.nbytes)) else {
                    throw ProbeError("Qwen vision tensor is not an owned exact source allocation")
                }
                remaining -= try Memory.allocationFootprintUpperBound(byteCount: descriptor.byteCount)
                cursor += 1
                return array
            }, checkpoint: { arrays in eval(arrays); Stream.gpu.synchronize(); try check() })
            guard remaining == 0, cursor == inventory.descriptors.count,
                loaded.trainableParameters().flattened().isEmpty else {
                throw ProbeError("Qwen vision LOAD did not finish")
            }
            try checkpoint.checkUnchanged(); try check()
        } catch { throw QwenStageVisionLoadFailure(cause: error, retained: loaded) }
    }
}
