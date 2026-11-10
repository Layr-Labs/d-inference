import Foundation
import MLX
import MLXLLM

/// What one rank of a MiMo tensor-parallel load read and holds. The verified
/// artifact and the plan fingerprint are equal on both ranks (compared before
/// either serves); the byte counts are this rank's own.
struct MiMoTensorParallelShardReceipt: Equatable, Sendable {
    let verifiedAggregateSHA256: String
    let planFingerprint: String
    let rank: Int
    /// Text tensors read, and the excluded components' tensors skipped by name.
    let textTensors: Int
    let excludedTensors: Int
    /// The text tensors' whole stored bytes, and the bytes this rank read of them.
    let textBytes: Int
    let readBytes: Int
    let shardBytes: Int
    let loadNanoseconds: UInt64
}

/// One rank's shard of a verified MiMo V2.6 checkpoint
/// (`MiMoTensorParallelPlan`). The caller hands over a checkpoint whose every
/// file already matched its manifest (`VerifiedCheckpoint`: the registered
/// artifact through `prepareMiMoResidentSource`). Then, per indexed tensor in
/// name order: excluded components are skipped by name, every other name must
/// be a text tensor of the plan with the plan's stored shape and a stored
/// dtype of the artifact, and only this rank's byte runs are read (one run
/// per index of the dimensions before the cut axis: the SDK's
/// `MiMoV26TensorShard.byteRuns`, read uncached through the pinned
/// descriptor, runs that share pages in one aligned read). Any difference
/// refuses the load; nothing of a divided tensor outside this rank's half is
/// kept.
enum MiMoTensorParallelVerifiedLoad {
    static let storedDTypes: Set<DType> = [.uint32, .uint8, .bfloat16, .float32]

    /// `beforeRead(name, bytes)` runs before each read (a host gate, a
    /// cooperative check); `check` after each.
    static func load(checkpoint: VerifiedCheckpoint, configurationData: Data, role: MiMoTensorParallelModel.Role,
                     reduction: QwenTensorParallelReduction?,
                     beforeRead: (String, Int) throws -> Void = { _, _ in },
                     check: () throws -> Void = {}) throws
        -> (model: MiMoTensorParallelModel, receipt: MiMoTensorParallelShardReceipt) {
        let started = DispatchTime.now().uptimeNanoseconds
        try checkpoint.requireConfiguration(configurationData)
        let plan = try MiMoTensorParallelPlan(configuration: configurationData)
        let descriptors = try tensorDescriptors(checkpoint: checkpoint,
            scope: .init(acceptsUInt8: true, indexedShardsOnly: true))
        let rank: Int
        switch role {
        case .full: rank = 0
        case .shard(let value): rank = value
        }
        let shard = try MiMoV26TensorShard(rank: rank, size: plan.size)
        // Every name is disposed of before the first read.
        var reads: [(name: String, descriptor: TensorDescriptor, selection: TensorSelection, bytes: Int)] = []
        var excluded = 0, textBytes = 0
        for name in descriptors.keys.sorted() {
            let descriptor = descriptors[name]!
            if case .excluded = try plan.disposition(of: name) { excluded += 1; continue }
            guard try plan.expectedShape(key: name) == descriptor.shape, storedDTypes.contains(descriptor.dtype) else {
                throw ProbeError("MiMo tensor parallel load: \(name) is stored as \(descriptor.dtype) \(descriptor.shape), not the plan's")
            }
            textBytes += descriptor.byteCount
            guard case .shard = role, let axis = try plan.cut(key: name) else {
                reads.append((name, descriptor, .all, descriptor.byteCount))
                continue
            }
            let local = try plan.localShape(key: name, shape: descriptor.shape)
            let half = local[axis]
            let selection = TensorSelection.axis(axis, [(rank * half) ..< ((rank + 1) * half)])
            // The selection's runs are the SDK shard's byte runs, exactly.
            let runs = try shard.byteRuns(shape: descriptor.shape, axis: axis, bytes: descriptor.byteCount)
            let inner = descriptor.shape[(axis + 1)...].reduce(descriptor.dtype.size, *)
            guard runs.count == descriptor.shape[..<axis].reduce(1, *), runs.stride == descriptor.shape[axis] * inner,
                  runs.offset == rank * half * inner, runs.length == half * inner,
                  runs.bytes == local.reduce(descriptor.dtype.size, *) else {
                throw ProbeError("MiMo tensor parallel load: \(name)'s byte runs differ from the SDK shard's")
            }
            reads.append((name, descriptor, selection, runs.bytes))
        }
        guard !reads.isEmpty else { throw ProbeError("MiMo tensor parallel load: the checkpoint holds no text tensor") }
        try checkpoint.checkUnchanged()
        try checkpoint.bypassTensorPayloadCache()
        var readBytes = 0
        let model = try MiMoTensorParallelModel.assemble(configurationData: configurationData, role: role,
            reduction: reduction, parts: .rankParts) { keep in
            for (name, descriptor, selection, bytes) in reads {
                try autoreleasepool {
                    try beforeRead(name, bytes)
                    let read = try descriptor.read(selection)
                    guard read.copiedBytes == bytes, read.array.nbytes == bytes,
                          read.array.shape == (try selection.resultShape(descriptor.shape)),
                          read.readAccounting.map({ $0.selectedBytes == read.copiedBytes }) ?? false else {
                        throw ProbeError("MiMo tensor parallel load: \(name)'s read differs from its runs")
                    }
                    readBytes += bytes
                    try keep(name, read.array)
                    try check()
                }
            }
        }
        try checkpoint.checkUnchanged()
        try check()
        return (model, .init(verifiedAggregateSHA256: checkpoint.aggregate, planFingerprint: plan.fingerprint, rank: rank,
            textTensors: reads.count, excludedTensors: excluded, textBytes: textBytes, readBytes: readBytes,
            shardBytes: model.loadedParameterBytes, loadNanoseconds: DispatchTime.now().uptimeNanoseconds - started))
    }
}

extension MiMoTensorParallelModel {
    /// A checkpoint directory with its own `manifest.json` (tools and
    /// oracles: synthetic checkpoints): every file is hashed against the
    /// manifest first (six at a time), then this rank's byte runs are read
    /// (`MiMoTensorParallelVerifiedLoad`). `expectedAggregateSHA256` pins the
    /// artifact when the caller knows it. The receipt's fields, for reports.
    public static func loadVerified(modelDirectory: URL, role: Role, reduction: QwenTensorParallelReduction?,
                                    expectedAggregateSHA256: String? = nil) throws
        -> (model: MiMoTensorParallelModel, aggregateSHA256: String, readBytes: Int, textBytes: Int) {
        let configurationData = try Data(contentsOf: modelDirectory.appendingPathComponent("config.json"))
        let checkpoint = try VerifiedCheckpoint(directory: modelDirectory, configurationData: configurationData,
            expectedAggregateSHA256: expectedAggregateSHA256,
            hashingConcurrency: MiMoRegisteredSpecification.hashingConcurrency)
        let loaded = try MiMoTensorParallelVerifiedLoad.load(checkpoint: checkpoint,
            configurationData: configurationData, role: role, reduction: reduction)
        return (loaded.model, loaded.receipt.verifiedAggregateSHA256, loaded.receipt.readBytes, loaded.receipt.textBytes)
    }
}
