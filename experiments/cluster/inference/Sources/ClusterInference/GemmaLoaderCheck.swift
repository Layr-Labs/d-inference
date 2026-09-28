import Foundation
import MLX

private struct GemmaLoaderAccounting: Encodable {
    let sourceModelTensorBytes: Int
    let sourceFFNTensorBytes: Int
    let sourceShardedFFNTensorBytes: Int
    let sourceShardedTensorBytes: Int
    let selectedSourceTensorBytes: Int
    let selectedShardedTensorBytes: Int
    let largestSelectedSourceTensorBytes: Int
    let allocationFootprintUpperBoundBytes: Int
    let selectedTensorCount: Int
    let tensorCount: Int

    init(fixture: LoaderFixture, plan: GemmaPartitionPlan, rank: Int) throws {
        var total = 0, ffn = 0, shardedFFN = 0, sharded = 0
        var selected = 0, selectedSharded = 0, largest = 0, footprint = 0, count = 0
        for (name, value) in fixture.parameters {
            let selection = try plan.selection(name: name, shape: value.shape, rank: rank)
            let bytes = try selection.resultShape(value.shape).reduce(value.dtype.size, *)
            total += value.nbytes
            if plan.isFeedForwardTensor(name: name) {
                ffn += value.nbytes
                if selection != .all { shardedFFN += value.nbytes }
            }
            if selection != .all {
                sharded += value.nbytes; selectedSharded += bytes; count += 1
            }
            selected += bytes; largest = max(largest, bytes)
            footprint += try Memory.allocationFootprintUpperBound(byteCount: bytes)
        }
        guard selected == total - sharded + selectedSharded,
            sharded > 0, shardedFFN == sharded, ffn > shardedFFN else {
            throw ProbeError("Gemma fixture did not exercise unequal FFN ownership and replicated routing")
        }
        sourceModelTensorBytes = total; sourceFFNTensorBytes = ffn
        sourceShardedFFNTensorBytes = shardedFFN; sourceShardedTensorBytes = sharded
        selectedSourceTensorBytes = selected; selectedShardedTensorBytes = selectedSharded
        largestSelectedSourceTensorBytes = largest; allocationFootprintUpperBoundBytes = footprint
        selectedTensorCount = count; tensorCount = fixture.parameters.count
    }

    func verify(_ receipt: DirectShardLoadReceipt, fixture: LoaderFixture, rank: Int) throws {
        let storage = receipt.partitionStorage
        guard receipt.rank == rank, receipt.verifiedAggregateSHA256 == fixture.aggregateSHA256,
            receipt.sourceModelTensorBytes == sourceModelTensorBytes,
            receipt.sourceFFNTensorBytes == sourceFFNTensorBytes,
            receipt.sourceShardedFFNTensorBytes == sourceShardedFFNTensorBytes,
            receipt.sourceShardedTensorBytes == sourceShardedTensorBytes,
            receipt.loadedTensorBytes == selectedSourceTensorBytes,
            receipt.largestHostTensorBytes == largestSelectedSourceTensorBytes,
            receipt.tensorCount == tensorCount, receipt.sourceTensorCount == fixture.sourceTensorCount,
            storage.schemaVersion == 1, storage.ranks.count == 2,
            storage.sourceModelTensorBytes == sourceModelTensorBytes,
            storage.sourceFFNTensorBytes == sourceFFNTensorBytes,
            storage.sourceShardedFFNTensorBytes == sourceShardedFFNTensorBytes,
            storage.sourceShardedTensorBytes == sourceShardedTensorBytes,
            storage.ranks[rank].rank == rank,
            storage.ranks[rank].loadedTensorBytes == selectedSourceTensorBytes,
            storage.ranks[rank].selectedShardedTensorBytes == selectedShardedTensorBytes else {
            throw ProbeError("Gemma loader receipt differs from independent fixture byte accounting")
        }
    }
}

private struct GemmaLoaderResult: Encodable {
    let kind = "gemma_direct_shard_loader_parity"
    let syntheticProfile: String
    let partition = "ffn"
    let partitionPlanSHA256: String
    let fp16FFNMetadata: Bool
    let fp16MetadataScope = "all-layer-quantization-scales-and-offsets"
    let fp16MetadataTensorCount: Int
    let tensorChecks: Int
    let tensorChecksAfterSourceDeletion: Int
    let independentBuffers = true
    let sourceFilesDeleted = true
    let rejectedCorruptionRanks: [Int]
    let peakMLXLoadDeltaBytes: [Int]
    let residentTensorBytes: [Int]
    let sourceByteAccounting: [GemmaLoaderAccounting]
    let receipts: [DirectShardLoadReceipt]
    let modelLogitParityCompared = false
}

/// Storage oracle only: whole-model Gemma TP execution is checked separately.
func checkGemmaLoader(_ options: Options) throws {
    guard options.synthetic, ["gemma-moe", "gemma-moe-w8"].contains(options.syntheticProfile),
        options.syntheticDType == "float32", options.partition == .ffn,
        (ProcessInfo.processInfo.environment["DARKBLOOM_BF16_WEIGHTS"] ?? "1") == "1" else {
        throw ProbeError("Gemma loader check requires a synthetic F32 Gemma MoE profile, FFN partition and BF16 conversion enabled")
    }
    try checkGemmaLoaderCase(options, fp16Metadata: false)
    try checkGemmaLoaderCase(options, fp16Metadata: true)
}

private func gemmaLoaderOracle(
    _ baseline: LoadedModel, fixture: LoaderFixture, plan: GemmaPartitionPlan, rank: Int
) throws -> [String: MLXArray] {
    var result: [String: MLXArray] = [:]
    for (name, value) in baseline.model.parameters().flattened() {
        guard let stored = fixture.parameters[name],
            value.dtype == (stored.dtype == .float16 ? .bfloat16 : stored.dtype) else {
            throw ProbeError("Ordinary Gemma fixture load did not apply the expected metadata conversion")
        }
        // This gathers an ordinary loaded source array; it does not use the
        // direct reader's byte ranges or its metadata/layout commitment factory.
        result[name] = try copySelectedTensor(value,
            selection: plan.selection(name: name, shape: value.shape, rank: rank))
    }
    guard result.count == fixture.parameters.count else { throw ProbeError("Gemma oracle source keys differ") }
    return result
}

private func checkGemmaLoadedStorage(
    _ loaded: LoadedModel, expected: [String: MLXArray], phase: String
) throws -> (checks: Int, residentBytes: Int) {
    let parameters = Dictionary(uniqueKeysWithValues: loaded.model.parameters().flattened())
    guard Set(parameters.keys) == Set(expected.keys) else { throw ProbeError("Gemma loaded parameter keys differ") }
    var resident = 0
    for name in parameters.keys.sorted() {
        let actual = parameters[name]!, reference = expected[name]!
        guard actual.shape == reference.shape, actual.dtype == reference.dtype,
            actual.asData().data == reference.asData().data else {
            throw ProbeError("Gemma selected tensor differs from the independent oracle (\(phase)): \(name)")
        }
        guard let buffer = try actual.evaluatedBufferInfo(), buffer.dataOffset == 0,
            buffer.isRowContiguous, buffer.isUnique, buffer.dataElements == actual.size,
            buffer.allocatedBytes >= actual.nbytes,
            buffer.allocatedBytes <= (try Memory.allocationFootprintUpperBound(byteCount: actual.nbytes)) else {
            throw ProbeError("Gemma tensor lacks owned, compact, zero-offset storage (\(phase)): \(name)")
        }
        resident += actual.nbytes
    }
    let layout = expected.map { name, value in "\(name):\(value.dtype):\(value.shape)" }
        .sorted().joined(separator: "\n")
    guard loaded.parameterLayoutSHA256 == sha256(Data(layout.utf8)) else {
        throw ProbeError("Gemma loaded layout differs from the independently selected oracle")
    }
    return (parameters.count, resident)
}

private func checkGemmaLoaderCase(_ options: Options, fp16Metadata: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cluster-gemma-loader-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var generationOptions = options
    generationOptions.mode = .baseline
    let generated = try loadModel(generationOptions)
    let fixture = try writeLoaderFixture(generated, directory: directory, fp16FFNMetadata: fp16Metadata)
    guard generated.family == .gemma4, fixture.sourceTensorCount == fixture.parameters.count,
        fixture.sourcePartsPerTensor.values.allSatisfy({ $0 == 1 }),
        (fixture.fp16MetadataTensorCount > 0) == fp16Metadata else {
        throw ProbeError("Gemma fixture did not exercise canonical split expert storage and requested metadata")
    }
    let plan = try GemmaPartitionPlan(configuration: generated.configurationData)
    var saved = generationOptions
    saved.synthetic = false; saved.modelDirectory = directory
    let baseline = try loadModel(saved)
    let accounting = try (0..<2).map { try GemmaLoaderAccounting(fixture: fixture, plan: plan, rank: $0) }
    guard accounting[0].selectedShardedTensorBytes + accounting[1].selectedShardedTensorBytes
            == accounting[0].sourceShardedTensorBytes,
        accounting[0].selectedSourceTensorBytes < accounting[1].selectedSourceTensorBytes else {
        throw ProbeError("Gemma fixture failed to exercise unequal, conserving rank payloads")
    }
    var shards: [LoadedModel] = [], oracles: [[String: MLXArray]] = []
    var peakDeltas: [Int] = [], residentBytes: [Int] = [], checks = 0
    for rank in 0..<2 {
        Memory.clearCache()
        let before = Memory.activeMemory
        Memory.peakMemory = 0
        let loaded = try loadModel(saved, partitionRank: rank)
        let delta = max(0, Memory.peakMemory - before)
        peakDeltas.append(delta)
        guard let receipt = loaded.directShardLoad, let storage = loaded.partitionStorage,
            loaded.partitionPlan?.fingerprint == plan.fingerprint,
            storage.ranks.count == 2,
            try storage.fingerprint == receipt.partitionStorage.fingerprint,
            loaded.parameterLayoutSHA256 == storage.ranks[rank].parameterLayoutSHA256 else {
            throw ProbeError("Gemma direct load has no matching plan/storage receipt")
        }
        try accounting[rank].verify(receipt, fixture: fixture, rank: rank)
        // Each rank has its own bound; a half-source threshold is invalid for
        // odd group counts. The fixture is large enough to distinguish a full
        // source allocation from bounded selected-tensor loading.
        guard delta < accounting[rank].sourceModelTensorBytes,
            delta <= accounting[rank].allocationFootprintUpperBoundBytes
                + 2 * accounting[rank].largestSelectedSourceTensorBytes + 65_536 else {
            throw ProbeError("Gemma direct load exceeded its selected-storage transient bound")
        }
        let oracle = try gemmaLoaderOracle(baseline, fixture: fixture, plan: plan, rank: rank)
        let checked = try checkGemmaLoadedStorage(loaded, expected: oracle, phase: "after load")
        guard checked.residentBytes == accounting[rank].selectedSourceTensorBytes else {
            throw ProbeError("Gemma selected source and resident bytes differ for an equal-width dtype conversion")
        }
        checks += checked.checks; residentBytes.append(checked.residentBytes)
        shards.append(loaded); oracles.append(oracle)
    }
    guard try shards[0].partitionStorage!.fingerprint == shards[1].partitionStorage!.fingerprint else {
        throw ProbeError("Gemma ranks disagree on ordered storage commitments")
    }
    let checkpoint = directory.appendingPathComponent("weights-0.safetensors")
    var corrupt = try Data(contentsOf: checkpoint)
    corrupt[corrupt.count - 1] ^= 1
    try corrupt.write(to: checkpoint)
    var rejected: [Int] = []
    for rank in 0..<2 {
        do { _ = try loadModel(saved, partitionRank: rank) }
        catch { if String(describing: error).contains("SHA256 mismatch") { rejected.append(rank) } }
    }
    guard rejected == [0, 1] else { throw ProbeError("Gemma corrupt source was not rejected on both ranks") }
    try FileManager.default.removeItem(at: directory)
    guard !FileManager.default.fileExists(atPath: directory.path) else { throw ProbeError("Gemma source files remain present") }
    var deletionChecks = 0
    for rank in 0..<2 {
        let checked = try checkGemmaLoadedStorage(shards[rank], expected: oracles[rank], phase: "after source corruption/deletion")
        guard checked.residentBytes == residentBytes[rank] else { throw ProbeError("Gemma residency changed after source deletion") }
        deletionChecks += checked.checks
    }
    try emitJSON(GemmaLoaderResult(syntheticProfile: options.syntheticProfile, partitionPlanSHA256: plan.fingerprint,
        fp16FFNMetadata: fp16Metadata, fp16MetadataTensorCount: fixture.fp16MetadataTensorCount,
        tensorChecks: checks, tensorChecksAfterSourceDeletion: deletionChecks,
        rejectedCorruptionRanks: rejected, peakMLXLoadDeltaBytes: peakDeltas, residentTensorBytes: residentBytes,
        sourceByteAccounting: accounting, receipts: shards.compactMap(\.directShardLoad)))
}
