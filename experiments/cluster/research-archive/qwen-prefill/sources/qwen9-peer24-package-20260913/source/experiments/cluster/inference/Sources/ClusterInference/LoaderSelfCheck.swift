import Foundation
import MLX

func checkDirectShardLoader(_ options: Options) throws {
    try checkDirectShardLoader(options, fp16FFNMetadata: false)
    try checkDirectShardLoader(options, fp16FFNMetadata: true)
}

private func checkLoaderTensorStorage(
    _ loaded: LoadedModel, expected: [String: MLXArray], phase: String
) throws -> (checks: Int, residentBytes: Int) {
    let actual = Dictionary(uniqueKeysWithValues: loaded.model.parameters().flattened())
    guard Set(actual.keys) == Set(expected.keys) else { throw ProbeError("Loaded shard parameter keys differ") }
    var bytes = 0
    for key in actual.keys.sorted() {
        let value = actual[key]!
        guard let reference = expected[key], value.shape == reference.shape, value.dtype == reference.dtype,
            value.asData().data == reference.asData().data else {
            throw ProbeError("Direct loader differs from in-memory slice oracle (\(phase)): \(key)")
        }
        guard let buffer = try value.evaluatedBufferInfo(), buffer.dataOffset == 0,
            buffer.isRowContiguous, buffer.dataElements == value.size,
            buffer.isUnique, buffer.allocatedBytes >= value.nbytes,
            buffer.allocatedBytes <= (try Memory.allocationFootprintUpperBound(byteCount: value.nbytes))
        else { throw ProbeError("Direct loader lacks an owned, compact, zero-offset allocation (\(phase)): \(key)") }
        bytes += value.nbytes
    }
    return (actual.count, bytes)
}

private struct LoaderParityResult: Encodable {
    let kind = "direct_shard_loader_parity"
    let partition: String
    let partitionPlanSHA256: String
    let fp16FFNMetadata: Bool
    let fp16MetadataScope = "all-layer-quantization-scales-and-offsets"
    let fp16MetadataTensorCount: Int
    let tensorChecks: Int
    let tensorChecksAfterSourceDeletion: Int
    let independentBuffers = true
    let sourceFilesDeleted = true
    let rejectedCorruption: Bool
    let rejectedCorruptionRanks: [Int]
    let peakMLXLoadDeltaBytes: [Int]
    let residentTensorBytes: [Int]
    let sourceByteAccounting: [LoaderSourceAccounting]
    let receipts: [DirectShardLoadReceipt]
    let modelLogitParityCompared: Bool
    let parity: ParityResult?
}

private func checkDirectShardLoader(_ options: Options, fp16FFNMetadata: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cluster-loader-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let generated = try loadModel(options)
    let fixture = try writeLoaderFixture(generated, directory: directory, fp16FFNMetadata: fp16FFNMetadata)
    guard (fixture.fp16MetadataTensorCount > 0) == fp16FFNMetadata else {
        throw ProbeError("Fixture did not exercise the requested metadata dtype")
    }
    let plan = try QwenPartitionPlan(configuration: generated.configurationData, kind: options.partition)
    var savedOptions = options
    savedOptions.synthetic = false; savedOptions.modelDirectory = directory
    savedOptions.mode = .baseline
    let baseline = try loadModel(savedOptions)
    var shards: [LoadedModel] = []
    var expectedByRank: [[String: MLXArray]] = []
    var accounting: [LoaderSourceAccounting] = []
    var tensorChecks = 0
    var peakDeltas: [Int] = []
    var residentBytes: [Int] = []
    for rank in 0..<2 {
        let source = try LoaderSourceAccounting(fixture, plan: plan, rank: rank)
        guard plan.kind == .full ? source.sourceShardedTensorBytes > source.sourceShardedFFNTensorBytes
            : source.sourceShardedTensorBytes == source.sourceShardedFFNTensorBytes else {
            throw ProbeError("Fixture did not exercise all requested partition components")
        }
        guard plan.isMoE ? source.sourceFFNTensorBytes > source.sourceShardedFFNTensorBytes
            : source.sourceFFNTensorBytes == source.sourceShardedFFNTensorBytes else {
            throw ProbeError("Fixture did not preserve the expected replicated router tensors")
        }
        Memory.clearCache()
        let before = Memory.activeMemory
        Memory.peakMemory = 0
        let loaded = try loadModel(savedOptions, partitionRank: rank)
        peakDeltas.append(max(0, Memory.peakMemory - before))
        guard let receipt = loaded.directShardLoad,
            loaded.partitionPlan?.fingerprint == plan.fingerprint else {
            throw ProbeError("Missing or mismatched direct loader partition receipt")
        }
        try source.verify(receipt, fixture: fixture, rank: rank)
        guard peakDeltas.last! < source.sourceModelTensorBytes else {
            throw ProbeError("Direct loading temporarily allocated at least the full fixture model")
        }
        let expected = try expectedShardParameters(baseline, rank: rank, plan: plan)
        let checked = try checkLoaderTensorStorage(loaded, expected: expected, phase: "after load")
        // F32 stays F32 and F16-to-BF16 preserves byte width in the tested loader.
        guard checked.residentBytes == source.selectedSourceTensorBytes else {
            throw ProbeError("Direct loader resident/source byte accounting differs for an equal-width conversion")
        }
        tensorChecks += checked.checks
        residentBytes.append(checked.residentBytes)
        shards.append(loaded); expectedByRank.append(expected); accounting.append(source)
    }

    let prompt = try promptTokens(options: options, vocabularySize: baseline.vocabularySize)
    let teacher = (0..<(options.decodeCount - 1)).map { 3 + (($0 * 13 + 9) % (baseline.vocabularySize - 3)) }
    let reference: Execution? = plan.kind == .ffn
        ? try execute(loaded: baseline, prompt: prompt, teacher: teacher,
                      options: options, iteration: 0, collectLogits: true) : nil

    let checkpoint = directory.appendingPathComponent("weights-0.safetensors")
    var corrupt = try Data(contentsOf: checkpoint)
    corrupt[corrupt.count - 1] ^= 1
    try corrupt.write(to: checkpoint)
    var rejectedRanks: [Int] = []
    for rank in 0..<2 {
        do { _ = try loadModel(savedOptions, partitionRank: rank) }
        catch {
            if String(describing: error).contains("SHA256 mismatch") { rejectedRanks.append(rank) }
        }
    }
    guard rejectedRanks == [0, 1] else { throw ProbeError("Modified weight bytes were not rejected by both ranks") }
    try FileManager.default.removeItem(at: directory)
    guard !FileManager.default.fileExists(atPath: directory.path) else {
        throw ProbeError("Loader fixture source files remain present")
    }
    var deletionChecks = 0
    for rank in 0..<2 {
        let checked = try checkLoaderTensorStorage(shards[rank], expected: expectedByRank[rank],
                                                 phase: "after source corruption and deletion")
        guard checked.residentBytes == residentBytes[rank] else { throw ProbeError("Loaded storage changed after source deletion") }
        deletionChecks += checked.checks
    }
    var parity: ParityResult?
    if let reference {
        // This full-model oracle installs only FFN modules. Full partition tensor
        // parity must not claim attention/GDN model execution was compared here.
        try combineLoadedShards(into: baseline, shards: shards)
        let candidate = try execute(loaded: baseline, prompt: prompt, teacher: teacher,
                                    options: options, iteration: 0, collectLogits: true)
        let compared = try compare(reference, candidate)
        guard compared.passed else { throw ProbeError("Direct-loaded shard model parity failed") }
        parity = compared
    }
    try emitJSON(LoaderParityResult(partition: plan.kind.rawValue, partitionPlanSHA256: plan.fingerprint,
        fp16FFNMetadata: fp16FFNMetadata, fp16MetadataTensorCount: fixture.fp16MetadataTensorCount,
        tensorChecks: tensorChecks, tensorChecksAfterSourceDeletion: deletionChecks,
        rejectedCorruption: true, rejectedCorruptionRanks: rejectedRanks,
        peakMLXLoadDeltaBytes: peakDeltas, residentTensorBytes: residentBytes,
        sourceByteAccounting: accounting, receipts: shards.compactMap(\.directShardLoad),
        modelLogitParityCompared: parity != nil, parity: parity))
}
