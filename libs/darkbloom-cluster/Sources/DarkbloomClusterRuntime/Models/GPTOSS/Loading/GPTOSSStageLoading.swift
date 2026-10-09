import Foundation
import MLX
import MLXLLM
import MLXNN

/// A compact stage is not a complete model. Only the GPT-OSS stage session may
/// consume it: stage 0 takes token IDs and exports the residual before the
/// final norm, stage 1 takes that residual and produces logits.
struct LoadedGPTOSSLayerStage {
    let model: GPTOSSModel
    /// Stage 1 only: the model's own output head, as its module tree holds it.
    let head: Linear?
    let plan: GPTOSSLayerStagePlan
    let stageIndex: Int
    let receipt: QwenLayerStageLoadReceipt
    let activationDType: DType
    let vocabularySize: Int

    var layerCount: Int { plan.stages[stageIndex].layers.count }
}

/// The ordered resource gate of one GPT-OSS stage load: before each tensor has
/// its storage, the host memory policy is asked for everything still to come
/// (the remaining tensors, two host copies of the largest, the read scratch
/// and the loading headroom) and the allocator limit is checked.
final class GPTOSSStageLoadGate: QwenLayerStageGate {
    let active: [QwenStageActiveTensor], bounds: [Int], inert: Int, host: Int
    private var next = 0
    private var failed = false
    private let watch = QwenDenseStageLoadWatch("Resident load")

    init(inventory: GPTOSSStagePreparedInventory) throws {
        active = inventory.active; host = active.map(\.byteCount).max() ?? 0
        bounds = try active.map { try Memory.allocationFootprintUpperBound(byteCount: $0.byteCount) }
        let inertBounds = try inventory.inert.flatMap(\.parameters).map {
            try Memory.allocationFootprintUpperBound(byteCount: $0.byteCount)
        }
        inert = try QwenLongPrefillCheckedBytes.sum(inertBounds)
        let maximum = GPU.deviceInfo().maxBufferSize
        guard !active.isEmpty, host > 0, maximum > 0, bounds.allSatisfy({ $0 > 0 && $0 <= maximum }),
              inertBounds.allSatisfy({ $0 > 0 && $0 <= maximum }) else {
            throw ProbeError("GPT-OSS stage buffers exceed actual device bounds")
        }
        try observe()
    }

    func observe() throws {
        do {
            guard !failed else { throw ProbeError("GPT-OSS stage load gate was poisoned") }
            let remaining = try QwenLongPrefillCheckedBytes.sum(Array(bounds.dropFirst(next)) + [inert])
            let h = next < active.count ? host : 0
            let scratch = h == 0 ? 0 : CheckpointAlignedReadPlan.maximumScratchAllocationBytes
            let required = max(QwenDenseStageLoadPolicy.minimumAdmissibleBytes,
                try QwenLongPrefillCheckedBytes.sum([remaining, h, h, scratch, QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
            let allocator = try QwenLongPrefillCheckedBytes.sum([Memory.activeMemory, Memory.cacheMemory,
                remaining, h, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
            let os = try QwenDenseStageLoadResources.observeOS()
            guard try watch.admits(os, bytes: required) else { throw ProbeError("GPT-OSS stage load was refused") }
            guard Memory.memoryLimit >= allocator else {
                throw ProbeError("GPT-OSS stage load exceeds the allocator limit: needs \(allocator) of \(Memory.memoryLimit) bytes")
            }
        } catch { failed = true; throw error }
    }

    func beforeRead(_ entry: QwenStageActiveTensor) throws {
        guard active.indices.contains(next), active[next].sourceName == entry.sourceName,
              active[next].localName == entry.localName, active[next].shape == entry.shape,
              active[next].sourceDType == entry.sourceDType, active[next].loadedDType == entry.loadedDType,
              active[next].byteCount == entry.byteCount else {
            failed = true; throw ProbeError("GPT-OSS stage load changed its admitted ordered tensor inventory")
        }
        try observe(); next += 1
    }

    func finish() throws {
        guard next == active.count else { failed = true; throw ProbeError("GPT-OSS stage load incomplete") }
        try observe()
    }
}

/// Loads one rank's stage from this Mac's verified artifact. Everything about
/// the source, both compact inventories and the allocation limits is checked
/// before the first tensor is read; each tensor is then one aligned, uncached
/// read through its pinned descriptor, behind the gate.
///
/// `constructed` receives the stage's model as soon as it exists, before any
/// tensor is read, so a caller's weak reference also answers for a load that
/// fails part-way.
func loadGPTOSSResidentStage(source: GPTOSSResidentSource, stageIndex index: Int, check: () throws -> Void,
                             constructed: (Module) -> Void = { _ in }) throws -> LoadedGPTOSSLayerStage {
    let plan = source.plan
    guard plan.stages.count == 2, (0...1).contains(index) else { throw ProbeError("GPT-OSS stage load requires a two-stage Plan") }
    let other = try withRandomState(MLXRandom.RandomState(seed: 7)) {
        try inspectOtherGPTOSSStage(source: source, stage: plan.stages[1 - index], check: check)
    }
    return try autoreleasepool {
        try withRandomState(MLXRandom.RandomState(seed: 7)) {
            let value = try prepareGPTOSSStageModel(source: source, stage: plan.stages[index], check: check)
            constructed(value.model)
            let inventories = [other, value.inventory].sorted { $0.summary.stageIndex < $1.summary.stageIndex }
            let coverage = inventories.flatMap(\.active)
            guard coverage.count == source.tensors.count,
                  Set(coverage.map(\.sourceName)) == Set(source.tensors.map(\.sourceName)),
                  coverage.reduce(0, { $0 + $1.byteCount }) == source.specification.sourceBytes else {
                throw ProbeError("GPT-OSS stage inventories do not exactly conserve the registered storage")
            }
            let commitment = QwenLayerStageStorageCommitment(schemaVersion: 1,
                verifiedAggregateSHA256: source.checkpoint.aggregate,
                sourceConfigurationSHA256: sha256(plan.originalConfiguration), planSHA256: plan.fingerprint,
                sourceTensorManifestSHA256: source.sourceTensorManifestSHA256,
                sourceModelTensorBytes: source.specification.sourceBytes,
                largestSourceTensorBytes: source.specification.largestTensorBytes,
                sourceTensorCount: source.tensors.count, canonicalTensorCount: source.tensors.count,
                bf16ConversionEnabled: false, stages: inventories.map(\.summary))
            let gate = try GPTOSSStageLoadGate(inventory: value.inventory)
            let loaded = try materializeGPTOSSStage(source: source, stageIndex: index, model: value.model,
                inventory: value.inventory, commitment: commitment, gate: gate,
                check: { try check(); try gate.observe(); try check() })
            try gate.finish(); try check()
            return loaded
        }
    }
}

private func materializeGPTOSSStage(source: GPTOSSResidentSource, stageIndex: Int, model: GPTOSSModel,
                                    inventory: GPTOSSStagePreparedInventory,
                                    commitment: QwenLayerStageStorageCommitment, gate: GPTOSSStageLoadGate,
                                    check: () throws -> Void) throws -> LoadedGPTOSSLayerStage {
    try source.checkpoint.checkUnchanged()
    try source.checkpoint.bypassTensorPayloadCache()
    var loadedBytes = 0, largestHostBytes = 0
    var readAccounting = CheckpointAlignedReadAccounting()
    for entry in inventory.active {
        try autoreleasepool {
            guard let descriptor = source.descriptors[entry.sourceName] else {
                throw ProbeError("Verified GPT-OSS stage descriptor disappeared")
            }
            try gate.beforeRead(entry)
            let read = try descriptor.read(.all)
            guard let accounting = read.readAccounting, accounting.selectedBytes == read.copiedBytes else {
                throw ProbeError("GPT-OSS stage aligned read accounting is incomplete")
            }
            let array = read.array
            eval(array)
            // eval can return before Metal completion handlers release their references.
            Stream.gpu.synchronize()
            try check()
            guard array.shape == entry.shape, String(describing: array.dtype) == entry.loadedDType,
                  array.nbytes == entry.byteCount, read.copiedBytes == entry.byteCount,
                  let buffer = try array.evaluatedBufferInfo(), buffer.isUnique, buffer.dataOffset == 0,
                  buffer.isRowContiguous, buffer.dataElements == array.size,
                  buffer.allocatedBytes >= array.nbytes,
                  buffer.allocatedBytes <= (try Memory.allocationFootprintUpperBound(byteCount: array.nbytes)) else {
                throw ProbeError("GPT-OSS stage tensor is not an exact, independently owned compact allocation: \(entry.localName)")
            }
            try model.update(parameters: ModuleParameters.unflattened([entry.localName: array]),
                             verify: [.noUnusedKeys, .shapeMismatch])
            try check()
            loadedBytes += read.copiedBytes
            largestHostBytes = max(largestHostBytes, read.copiedBytes)
            try readAccounting.merge(accounting)
        }
    }
    model.freeze()
    try check()
    // Freeze and parameter introspection evaluate nothing. Each active
    // parameter was evaluated above; the placeholders never are.
    let actual = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
    let activeLayout = try inventory.active.map { entry -> String in
        guard let value = actual[entry.localName], value.shape == entry.shape,
              String(describing: value.dtype) == entry.loadedDType else {
            throw ProbeError("GPT-OSS stage's resident active tensor layout differs: \(entry.localName)")
        }
        return "\(entry.localName):\(value.dtype):\(value.shape)"
    }
    guard loadedBytes == inventory.summary.loadedTensorBytes, readAccounting.selectedBytes == loadedBytes,
          largestHostBytes == (inventory.active.map(\.byteCount).max() ?? 0),
          modelParameterLayout(model) == inventory.summary.parameterLayoutSHA256,
          qwenStageLayout(activeLayout) == inventory.summary.activeParameterLayoutSHA256,
          model.trainableParameters().flattened().isEmpty else {
        throw ProbeError("Resident GPT-OSS stage storage or layout differs")
    }
    // The experts must still be the two separate projections the artifact stores.
    let names = Set(actual.keys)
    guard !names.contains(where: { $0.contains(".experts.gate_up_proj.") }),
          names.contains(where: { $0.hasSuffix(".mlp.experts.gate_proj.weight") }),
          names.contains(where: { $0.hasSuffix(".mlp.experts.up_proj.weight") }) else {
        throw ProbeError("Resident GPT-OSS stage does not hold the stored split expert layout")
    }
    var head: Linear?
    if stageIndex == 1 {
        guard let module = model.namedModules().first(where: { $0.0 == GPTOSSLayerStagePlan.head })?.1 as? Linear,
              !(module is GPTOSSStageDiscardedHead), actual[GPTOSSLayerStagePlan.head + ".weight"]?.dtype == .uint32,
              actual[GPTOSSLayerStagePlan.head + ".scales"]?.dtype == source.activationDType else {
            throw ProbeError("Resident GPT-OSS stage 1 does not hold the packed output head")
        }
        head = module
    } else {
        // Stage 0 must hold the artifact's own packed embedding before a token is looked up.
        guard actual[GPTOSSLayerStagePlan.embedding + ".weight"]?.dtype == .uint32,
              actual[GPTOSSLayerStagePlan.embedding + ".scales"]?.dtype == source.activationDType else {
            throw ProbeError("Resident GPT-OSS stage 0 does not hold the packed token embedding")
        }
    }
    try source.checkpoint.checkUnchanged()
    let summary = inventory.summary
    let receipt = QwenLayerStageLoadReceipt(schemaVersion: 1, stageIndex: stageIndex,
        verifiedAggregateSHA256: commitment.verifiedAggregateSHA256,
        sourceConfigurationSHA256: commitment.sourceConfigurationSHA256,
        constructionConfigurationSHA256: summary.constructionConfigurationSHA256,
        planSHA256: source.plan.fingerprint, stagePlanSHA256: summary.stagePlanSHA256,
        sourceTensorManifestSHA256: source.sourceTensorManifestSHA256,
        sourceParameterLayoutSHA256: source.sourceParameterLayoutSHA256,
        parameterLayoutSHA256: summary.parameterLayoutSHA256,
        activeParameterLayoutSHA256: summary.activeParameterLayoutSHA256,
        activeMappingSHA256: summary.activeMappingSHA256,
        embeddingActivationDType: String(describing: source.activationDType),
        bf16ConversionEnabled: false,
        sourceModelTensorBytes: source.specification.sourceBytes, loadedTensorBytes: loadedBytes,
        largestHostTensorBytes: largestHostBytes, activeTensors: inventory.active,
        inertModules: inventory.inert, inertTensorBytes: summary.inertTensorBytes,
        storageCommitment: commitment, storageCommitmentSHA256: sha256(try canonicalJSONData(commitment)),
        selectedPayloadReadAccounting: readAccounting)
    return LoadedGPTOSSLayerStage(model: model, head: head, plan: source.plan, stageIndex: stageIndex,
        receipt: receipt, activationDType: source.activationDType,
        vocabularySize: source.specification.vocabulary)
}
