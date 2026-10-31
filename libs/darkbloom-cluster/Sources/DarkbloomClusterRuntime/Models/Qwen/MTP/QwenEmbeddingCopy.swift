import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// `pipeline_mtp_v1`, the last rank: a copy of the producer stage's token
/// embedding, which the model's speculative head looks its input tokens up in
/// (stage 0 owns the embedding; the last rank never holds stage 0).
///
/// It is read with this rank's own stage, through the same verified
/// checkpoint (pinned descriptors of the files the stage load hashed against
/// the manifest, one aligned uncached read each), from the producer stage's
/// own inventory: every name, shape, stored and loaded dtype is what rank 0
/// loads for that tensor, and each read is checked against it. Each read asks
/// the host memory gate and the allocator limit first, for everything still
/// to come. The module takes the producer stage's declared quantization
/// (`PreparedQwenLayerSource.quantization`, affine only).
struct QwenEmbeddingCopy {
    let module: Embedding
    let bytes: Int
    let tensorNames: [String]
    let verifiedAggregateSHA256: String
    let planFingerprint: String
    /// When the copy began, and the allocator's active bytes then: the head's
    /// receipt measures the copy and the head together.
    let startedUptimeNanoseconds: UInt64
    let activeBytesBefore: Int

    /// The producer stage's embedding tensors, in inventory order: the
    /// table and, for a quantized table, its scales and biases.
    static func entries(producer inventory: QwenStagePreparedInventory) throws -> [QwenStageActiveTensor] {
        let entries = inventory.active.filter { entry in
            let path = entry.localName.split(separator: ".").dropLast().joined(separator: ".")
            return path == "model.embed_tokens" || path.hasSuffix(".model.embed_tokens")
        }
        let parts = entries.map { String($0.localName.split(separator: ".").last ?? "") }
        guard inventory.summary.stageIndex == 0, parts.contains("weight"), Set(parts).count == parts.count,
              Set(parts).isSubset(of: ["weight", "scales", "biases"]),
              Set(entries.map { $0.sourceName.split(separator: ".").dropLast().joined(separator: ".") }).count == 1 else {
            throw ProbeError("The producer stage holds no single token embedding to copy")
        }
        return entries
    }

    static func read(producer inventory: QwenStagePreparedInventory, source: PreparedQwenLayerSource,
                     payload: some QwenLayerStagePayloadSource, planFingerprint: String,
                     check: () throws -> Void) throws -> QwenEmbeddingCopy {
        let started = DispatchTime.now().uptimeNanoseconds
        Stream.gpu.synchronize()
        let before = Memory.snapshot().activeMemory
        let entries = try Self.entries(producer: inventory)
        let gate = try QwenEmbeddingCopyLoadGate(entries: entries)
        var arrays: [String: MLXArray] = [:]
        var bytes = 0
        for entry in entries {
            try autoreleasepool {
                let read = try payload.tensor(entry) { try check(); try gate.beforeRead($0); try check() }
                var array = read.array
                if source.bf16ConversionEnabled && array.dtype == .float16 { array = array.asType(.bfloat16) }
                eval(array)
                Stream.gpu.synchronize()
                try check()
                guard array.shape == entry.shape, read.copiedBytes == entry.byteCount, array.nbytes == entry.byteCount,
                      String(describing: array.dtype) == entry.loadedDType,
                      read.readAccounting.map({ $0.selectedBytes == read.copiedBytes }) ?? false,
                      let buffer = try array.evaluatedBufferInfo(), buffer.isUnique, buffer.dataOffset == 0,
                      buffer.isRowContiguous, buffer.dataElements == array.size else {
                    throw ProbeError("Embedding copy tensor is not an exact, independently owned compact allocation: \(entry.localName)")
                }
                arrays[String(entry.localName.split(separator: ".").last!)] = array
                bytes += entry.byteCount
            }
        }
        try gate.finish()
        try payload.finish()
        let sourcePath = entries[0].sourceName.split(separator: ".").dropLast().joined(separator: ".")
        let module = try Self.module(arrays, quantization: source.quantization[sourcePath],
            hiddenSize: source.hiddenSize, vocabularySize: source.vocabularySize)
        try check()
        return .init(module: module, bytes: bytes, tensorNames: entries.map(\.sourceName),
            verifiedAggregateSHA256: source.verifiedAggregateSHA256, planFingerprint: planFingerprint,
            startedUptimeNanoseconds: started, activeBytesBefore: before)
    }

    /// The module the head's target holds: a quantized table in the producer
    /// stage's declared layout, or a plain one. Shapes are checked by the
    /// module update (`shapeMismatch`); nothing lazy is ever evaluated.
    static func module(_ arrays: [String: MLXArray], quantization: BaseConfiguration.Quantization?,
                       hiddenSize: Int, vocabularySize: Int) throws -> Embedding {
        guard let weight = arrays["weight"], weight.ndim == 2, weight.dim(0) == vocabularySize else {
            throw ProbeError("Embedding copy has no table of the vocabulary's rows")
        }
        return try withRandomState(MLXRandom.RandomState(seed: 7)) {
            let lazy = Embedding(embeddingCount: vocabularySize, dimensions: hiddenSize)
            guard let quantization else {
                guard arrays.count == 1 else { throw ProbeError("An unquantized embedding copy is its table alone") }
                try lazy.update(parameters: ModuleParameters.unflattened(["weight": weight]),
                    verify: [.noUnusedKeys, .shapeMismatch])
                return lazy
            }
            guard quantization.mode == .affine, arrays["scales"] != nil, arrays["biases"] != nil, arrays.count == 3,
                  let packed = quantizeSingle(layer: lazy, groupSize: quantization.groupSize, bits: quantization.bits,
                      mode: quantization.mode) as? QuantizedEmbedding else {
                throw ProbeError("Embedding copy is not the producer stage's declared affine table")
            }
            try packed.update(parameters: ModuleParameters.unflattened(arrays), verify: [.noUnusedKeys, .shapeMismatch])
            return packed
        }
    }
}

/// The copy's ordered resource gate, as a stage load's: before each tensor is
/// read, the host memory policy is asked for everything still to come plus
/// two host copies of the largest, the read scratch and the loading headroom,
/// and the allocator limit is checked.
private final class QwenEmbeddingCopyLoadGate {
    private let entries: [QwenStageActiveTensor], bounds: [Int], host: Int
    private var next = 0
    private var failed = false
    private let watch = QwenDenseStageLoadWatch("Embedding copy load")

    init(entries: [QwenStageActiveTensor]) throws {
        self.entries = entries
        host = entries.map(\.byteCount).max() ?? 0
        bounds = try entries.map { try Memory.allocationFootprintUpperBound(byteCount: $0.byteCount) }
        let maximum = GPU.deviceInfo().maxBufferSize
        guard !entries.isEmpty, host > 0, maximum > 0, bounds.allSatisfy({ $0 > 0 && $0 <= maximum }) else {
            throw ProbeError("Embedding copy buffers exceed actual device bounds")
        }
        try observe()
    }

    private func observe() throws {
        do {
            guard !failed else { throw ProbeError("Embedding copy load gate was poisoned") }
            let remaining = try QwenLongPrefillCheckedBytes.sum(Array(bounds.dropFirst(next)))
            let h = next < entries.count ? host : 0
            let scratch = h == 0 ? 0 : CheckpointAlignedReadPlan.maximumScratchAllocationBytes
            let required = max(QwenDenseStageLoadPolicy.minimumAdmissibleBytes,
                try QwenLongPrefillCheckedBytes.sum([remaining, h, h, scratch, QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
            let allocator = try QwenLongPrefillCheckedBytes.sum([Memory.activeMemory, Memory.cacheMemory,
                remaining, h, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
            let os = try QwenDenseStageLoadResources.observeOS()
            guard try watch.admits(os, bytes: required) else { throw ProbeError("Embedding copy load was refused") }
            guard Memory.memoryLimit >= allocator else {
                throw ProbeError("Embedding copy load exceeds the allocator limit: needs \(allocator) of \(Memory.memoryLimit) bytes")
            }
        } catch { failed = true; throw error }
    }

    func beforeRead(_ entry: QwenStageActiveTensor) throws {
        guard entries.indices.contains(next), entries[next].sourceName == entry.sourceName,
              entries[next].shape == entry.shape, entries[next].byteCount == entry.byteCount else {
            failed = true; throw ProbeError("Embedding copy load changed its admitted ordered tensor inventory")
        }
        try observe()
        next += 1
    }

    func finish() throws {
        guard next == entries.count else { failed = true; throw ProbeError("Embedding copy load incomplete") }
        try observe()
    }
}
