import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// What one rank of a product tensor-parallel load read and holds: the
/// verified artifact and storage commitment it was read from (equal on both
/// ranks, compared before either serves), and this rank's own share.
struct QwenTensorParallelShardReceipt: Equatable {
    let verifiedAggregateSHA256: String
    let storageCommitmentSHA256: String
    let planName: String
    let shares: [Int]
    let rank: Int
    let sourceTensors: Int
    let sourceBytes: Int
    let shardBytes: Int
    let loadNanoseconds: UInt64
}

/// The product's tensor-parallel shard load (`tensor_parallel_v1`): this
/// rank's heads, key/value heads, MLP channels and vocabulary rows, read
/// through this Mac's verified checkpoint under the installed-file policy,
/// never from the files directly.
///
/// Both stages' inventories of the admitted plan are prepared and validated
/// exactly as a pipeline load prepares them, and together they must conserve
/// the canonical source (every tensor once): the storage commitment both
/// ranks compare. Each tensor is then one aligned, uncached read through its
/// pinned descriptor, checked against its inventory entry, asked of the host
/// memory gate first (`QwenTensorParallelLoadGate`), cut to this rank's share
/// and materialized at once; the whole tensor is released before the next is
/// read. A tensor no rank keeps (none in a registered dense text checkpoint)
/// is not read.
enum QwenTensorParallelVerifiedLoad {
    static func load(_ admission: QwenResidentAdmission, rank: Int, shares: [Int],
                     reduction: QwenTensorParallelReduction, partialDType: DType = .float32,
                     check: () throws -> Void) throws
        -> (model: QwenTensorParallelModel, receipt: QwenTensorParallelShardReceipt, profile: QwenRegisteredDenseModelProfile) {
        let started = DispatchTime.now().uptimeNanoseconds
        try admission.definition.arithmetic.requireNativeRoute()
        guard admission.definition.arithmetic == .dense, admission.specification.routedExperts == nil else {
            throw ProbeError("Tensor parallel serves the dense Qwen rows only")
        }
        let local = try prepareQwenResidentSource(admission, check: check)
        let source = local.metadata.source, plan = admission.plan
        // Both stages' inventories, validated as the pipeline validates them.
        let inventories = try (0..<plan.stages.count).map { index -> QwenStagePreparedInventory in
            let inventory = try withRandomState(MLXRandom.RandomState(seed: 7)) {
                try inspectOtherQwenLayerStage(source: source, stage: plan.stages[index], check: check)
            }
            try QwenDenseObservedStageValidation.validateRegistered(source: local.metadata.validation,
                profile: local.metadata.profile, requirement: local.metadata.pairRequirement, plan: plan, stageIndex: index,
                active: inventory.active, inert: inventory.inert, summary: inventory.summary)
            return inventory
        }
        let commitment = try qwenLayerStageStorageCommitment(source: source, originalConfiguration: admission.configBytes,
            plan: plan, inventories: inventories)
        let entries = inventories.flatMap(\.active)
        var receiptPlanName = "", shardBytes = 0
        let model = try QwenTensorParallelModel.assemble(configurationData: admission.configBytes,
            role: .shard(rank: rank, size: 2), reduction: reduction, partialDType: partialDType, shares: shares) { tpPlan, keep in
            receiptPlanName = tpPlan.name
            // The entries this rank keeps, and what each will hold after its cut.
            var kept: [(entry: QwenStageActiveTensor, bytes: Int)] = []
            for entry in entries {
                switch try tpPlan.disposition(key: entry.sourceName, rank: rank) {
                case .skip: continue
                case .load(let cut): kept.append((entry, Self.shareBound(entry.byteCount, cut: cut, plan: tpPlan, rank: rank)))
                }
            }
            let gate = try QwenTensorParallelLoadGate(entries: kept.map(\.entry), shardBounds: kept.map(\.bytes))
            try local.payload.begin(kept.map(\.entry), gate: gate)
            for (entry, _) in kept {
                try autoreleasepool {
                    let read = try local.payload.tensor(entry) { try check(); try gate.beforeRead($0); try check() }
                    var array = read.array
                    if source.bf16ConversionEnabled && array.dtype == .float16 { array = array.asType(.bfloat16) }
                    eval(array)
                    Stream.gpu.synchronize()
                    try check()
                    guard array.shape == entry.shape, read.copiedBytes == entry.byteCount, array.nbytes == entry.byteCount,
                          String(describing: array.dtype) == entry.loadedDType,
                          read.readAccounting.map({ $0.selectedBytes == read.copiedBytes }) ?? false else {
                        throw ProbeError("Tensor-parallel source tensor differs from its verified inventory: \(entry.localName)")
                    }
                    try keep(entry.sourceName, array)
                    try check(); try gate.observe()
                }
            }
            try gate.finish()
            try local.payload.finish()
        }
        shardBytes = model.loadedParameterBytes
        try check()
        return (model, .init(verifiedAggregateSHA256: commitment.verifiedAggregateSHA256,
            storageCommitmentSHA256: sha256(try canonicalJSONData(commitment)), planName: receiptPlanName, shares: shares,
            rank: rank, sourceTensors: entries.count, sourceBytes: source.sourceBytes, shardBytes: shardBytes,
            loadNanoseconds: DispatchTime.now().uptimeNanoseconds - started), local.metadata.profile)
    }

    /// An upper bound of what `cut` keeps of a tensor of `bytes`: the whole
    /// for a replicated tensor, this rank's weight of the shares otherwise,
    /// plus one percent for whole heads and quantization groups.
    static func shareBound(_ bytes: Int, cut: QwenTensorParallelPlan.Cut, plan: QwenTensorParallelPlan, rank: Int) -> Int {
        if cut == .replicate { return bytes }
        let total = plan.shares.reduce(0, +)
        let fraction = Double(plan.shares[rank]) / Double(max(1, total))
        return min(bytes, Int((Double(bytes) * min(1, fraction * 1.01)).rounded(.up)) + 4096)
    }
}

/// The shard load's ordered resource gate, as a stage load's: before each
/// tensor is read, the host memory policy is asked for the shard still to
/// come plus two host copies of the largest whole tensor (it is read whole,
/// then cut), the read scratch and the loading headroom, and the allocator
/// limit is checked.
final class QwenTensorParallelLoadGate: QwenLayerStageGate {
    private let entries: [QwenStageActiveTensor], bounds: [Int], host: Int
    private var next = 0
    private var failed = false
    private let watch = QwenDenseStageLoadWatch("Tensor-parallel shard load")

    init(entries: [QwenStageActiveTensor], shardBounds: [Int]) throws {
        guard entries.count == shardBounds.count, !entries.isEmpty else {
            throw ProbeError("Tensor-parallel shard load has no tensors")
        }
        self.entries = entries
        host = entries.map(\.byteCount).max() ?? 0
        bounds = try shardBounds.map { try Memory.allocationFootprintUpperBound(byteCount: max(1, $0)) }
        let maximum = GPU.deviceInfo().maxBufferSize
        guard host > 0, maximum > 0, bounds.allSatisfy({ $0 > 0 && $0 <= maximum }),
              (try entries.map { try Memory.allocationFootprintUpperBound(byteCount: $0.byteCount) }).allSatisfy({ $0 <= maximum }) else {
            throw ProbeError("Tensor-parallel shard buffers exceed actual device bounds")
        }
        try observe()
    }

    func observe() throws {
        do {
            guard !failed else { throw ProbeError("Tensor-parallel shard load gate was poisoned") }
            let remaining = try QwenLongPrefillCheckedBytes.sum(Array(bounds.dropFirst(next)))
            let h = next < entries.count ? host : 0
            let scratch = h == 0 ? 0 : CheckpointAlignedReadPlan.maximumScratchAllocationBytes
            let required = max(QwenDenseStageLoadPolicy.minimumAdmissibleBytes,
                try QwenLongPrefillCheckedBytes.sum([remaining, h, h, scratch, QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
            let allocator = try QwenLongPrefillCheckedBytes.sum([Memory.activeMemory, Memory.cacheMemory,
                remaining, h, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
            let os = try QwenDenseStageLoadResources.observeOS()
            guard try watch.admits(os, bytes: required), Memory.memoryLimit >= allocator else {
                throw ProbeError("Tensor-parallel shard load exceeds the allocator limit")
            }
        } catch { failed = true; throw error }
    }

    func beforeRead(_ entry: QwenStageActiveTensor) throws {
        guard entries.indices.contains(next), entries[next].sourceName == entry.sourceName,
              entries[next].shape == entry.shape, entries[next].byteCount == entry.byteCount else {
            failed = true; throw ProbeError("Tensor-parallel shard load changed its admitted ordered tensor inventory")
        }
        try observe(); next += 1
    }

    func finish() throws {
        guard next == entries.count else { failed = true; throw ProbeError("Tensor-parallel shard load incomplete") }
        try observe()
    }
}
