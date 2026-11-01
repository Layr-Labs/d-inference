import Foundation
import MLX
import MLXLMCommon

/// What one rank of a Gemma 4 tensor-parallel load read and holds: the
/// verified artifact and the storage commitment it was read under (equal on
/// both ranks, compared before either serves), and this rank's own share.
struct Gemma4TensorParallelShardReceipt: Equatable {
    let verifiedAggregateSHA256: String
    let storageCommitmentSHA256: String
    let rank: Int
    let sourceTensors: Int
    let sourceBytes: Int
    let shardBytes: Int
    let loadNanoseconds: UInt64
}

/// The product's Gemma 4 tensor-parallel shard load
/// (`gemma4_heads_and_expert_channels_v1`): this rank's heads, channels and
/// vocabulary rows, read through this Mac's verified checkpoint, never from
/// the files directly.
///
/// The whole artifact is verified first, as a pipeline load verifies it
/// (`prepareGemma4ResidentSource`: every file of the registered manifest
/// against its aggregate, the text tensors against the registered
/// inventory). Both pipeline stages' inventories are then prepared and must
/// conserve the source (the storage commitment both ranks compare). Every
/// text tensor must have the shape the plan expects of it; each is one
/// aligned, uncached read through its pinned descriptor, checked against its
/// inventory entry, asked of the host memory gate first
/// (`QwenTensorParallelLoadGate`), cut to this rank's part and materialized
/// at once, and released before the next is read. Vision tensors are not in
/// the text inventory and are never read; any other tensor the plan does not
/// cover refuses the load before a byte is read.
enum Gemma4TensorParallelVerifiedLoad {
    static func load(_ admission: Gemma4ResidentAdmission, rank: Int, reduction: QwenTensorParallelReduction,
                     additionalResidentBytes: Int = 0, check: () throws -> Void) throws
        -> (model: Gemma4TensorParallelModel, receipt: Gemma4TensorParallelShardReceipt) {
        guard additionalResidentBytes >= 0, reduction.rank == rank, reduction.size == 2 else {
            throw ProbeError("Gemma tensor-parallel load needs this rank's two-rank reduction")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let local = try prepareGemma4ResidentSource(admission, check: check)
        let source = local.metadata.source, stages = admission.plan
        let inventories = try (0..<stages.stages.count).map { index in
            try withRandomState(MLXRandom.RandomState(seed: 7)) {
                try inspectOtherGemma4LayerStage(source: local.metadata, stage: stages.stages[index], check: check)
            }
        }
        let commitment = try gemma4LayerStageStorageCommitment(source: source,
            originalConfiguration: admission.configBytes, plan: stages, inventories: inventories)
        guard let root = try JSONSerialization.jsonObject(with: admission.configBytes) as? [String: Any] else {
            throw ProbeError("Gemma tensor-parallel configuration is not an object")
        }
        let plan = try Gemma4TensorParallelPlan(configuration: root)
        let shard = try shardEntries(source.tensors, plan: plan, rank: rank)
        let gate = try QwenTensorParallelLoadGate(entries: shard.entries, shardBounds: shard.bytes,
            additionalResidentBytes: additionalResidentBytes)
        let model = try withRandomState(MLXRandom.RandomState(seed: 7)) {
            try Gemma4TensorParallelModel.assemble(configurationData: admission.configBytes, role: .shard(rank: rank),
                reduction: reduction) { keep in
                try local.payload.begin(shard.entries, gate: gate)
                for entry in shard.entries {
                    try autoreleasepool {
                        let read = try local.payload.tensor(entry) { try check(); try gate.beforeRead($0); try check() }
                        let array = read.array
                        eval(array)
                        Stream.gpu.synchronize()
                        try check()
                        guard array.shape == entry.shape, read.copiedBytes == entry.byteCount, array.nbytes == entry.byteCount,
                              String(describing: array.dtype) == entry.loadedDType,
                              read.readAccounting.map({ $0.selectedBytes == read.copiedBytes }) ?? false else {
                            throw ProbeError("Gemma tensor-parallel source tensor differs from its verified inventory: \(entry.sourceName)")
                        }
                        try keep(entry.sourceName, array)
                        try check(); try gate.observe()
                    }
                }
                try gate.finish()
                try local.payload.finish()
            }
        }
        try check()
        guard model.loadedParameterBytes == (try QwenLongPrefillCheckedBytes.sum(shard.bytes)) else {
            throw ProbeError("Gemma tensor-parallel shard holds other bytes than its plan cuts")
        }
        return (model, .init(verifiedAggregateSHA256: commitment.verifiedAggregateSHA256,
            storageCommitmentSHA256: sha256(try canonicalJSONData(commitment)), rank: rank,
            sourceTensors: shard.entries.count, sourceBytes: source.sourceBytes, shardBytes: model.loadedParameterBytes,
            loadNanoseconds: DispatchTime.now().uptimeNanoseconds - started))
    }

    /// Every text tensor once, in name order, as the load reads it, and what
    /// this rank holds of it after its cut (exact bytes: the plan's local
    /// shape at the stored element size). A tensor whose shape is not the
    /// plan's, whose cut does not fit it, or which the plan does not cover
    /// (vision, unknown, an untied head) refuses.
    static func shardEntries(_ tensors: [QwenStageSourceTensor], plan: Gemma4TensorParallelPlan, rank: Int) throws
        -> (entries: [QwenStageActiveTensor], bytes: [Int]) {
        guard !tensors.isEmpty, Set(tensors.map(\.sourceName)).count == tensors.count else {
            throw ProbeError("Gemma tensor-parallel source names a tensor twice or none")
        }
        var entries: [QwenStageActiveTensor] = [], bytes: [Int] = []
        for tensor in tensors.sorted(by: { $0.sourceName < $1.sourceName }) {
            guard tensor.secondPart == nil, try plan.expectedShape(key: tensor.sourceName) == tensor.shape else {
                throw ProbeError("Gemma tensor-parallel source tensor differs from the plan's shape: \(tensor.sourceName)")
            }
            let local = try plan.localShape(key: tensor.sourceName, shape: tensor.shape,
                cut: try plan.cut(key: tensor.sourceName, rank: rank))
            let elements = tensor.shape.reduce(1, *)
            guard elements > 0, tensor.byteCount % elements == 0 else {
                throw ProbeError("Gemma tensor-parallel source tensor bytes differ from its shape: \(tensor.sourceName)")
            }
            entries.append(.init(sourceName: tensor.sourceName, localName: tensor.sourceName, shape: tensor.shape,
                sourceDType: tensor.sourceDType, loadedDType: tensor.loadedDType, byteCount: tensor.byteCount))
            bytes.append(try QwenLongPrefillCheckedBytes.product([local.reduce(1, *), tensor.byteCount / elements]))
        }
        return (entries, bytes)
    }
}
