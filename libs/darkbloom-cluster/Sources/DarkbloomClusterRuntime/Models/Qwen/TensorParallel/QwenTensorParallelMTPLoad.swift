import Foundation
import MLX
import MLXLLM

/// Failed LOAD roots stay charged until the enclosing owner proves a native
/// drain. A thrown constructor is not permission to refund its reservation.
final class QwenTensorParallelMTPLoadFailure: Error, @unchecked Sendable {
    let cause: Error
    private var custody: QwenTensorParallelMTPLoadCustody?
    fileprivate init(_ cause: Error, custody: QwenTensorParallelMTPLoadCustody) {
        self.cause = cause; self.custody = custody
    }
    func releaseAfterCheckedDrain() { custody = nil }
}

/// A failed drain cannot transfer native roots into a printable error and then
/// drop them. The worker's one-shot process lease remains closed; this final
/// custody is released only by process exit, not by a caller catching the error.
final class QwenTensorParallelMTPAbandonedLoad: @unchecked Sendable {
    static let shared = QwenTensorParallelMTPAbandonedLoad()
    private let lock = NSLock()
    private var roots: [AnyObject] = []
    private var errors: [Error] = []

    func retain(_ error: Error, roots: [AnyObject]) {
        lock.lock(); defer { lock.unlock() }
        self.roots.append(contentsOf: roots)
        errors.append(error)
    }
}

private final class QwenTensorParallelMTPLoadCustody {
    var weights: [String: MLXArray] = [:]
    var assistant: Qwen35InlineMTPAssistant?
    var head: QwenTensorParallelMTPHead?
}

extension QwenTensorParallelMTPHead {
    static func load(source: QwenResidentLocalSource, configuration: Data,
                     inventory: QwenTensorParallelMTPInventory,
                     target: QwenTensorParallelModel, reduction: any QwenTensorParallelReduction,
                     remainingResidentAllowanceBytes: Int, check: () throws -> Void) throws -> QwenTensorParallelMTPHead {
        guard remainingResidentAllowanceBytes >= 0,
              inventory.configurationSHA256 == target.configurationSHA256,
              inventory.artifactSHA256 == source.payload.checkpoint.aggregate else {
            throw ProbeError("Qwen TP assistant LOAD differs from its admitted target")
        }
        let custody = QwenTensorParallelMTPLoadCustody()
        let checkpoint = source.payload.checkpoint
        let watch = QwenDenseStageLoadWatch("Qwen TP assistant LOAD")
        var remaining = inventory.allocationBytes
        func gate() throws {
            try check(); try checkpoint.checkUnchanged()
            let sum = QwenLongPrefillCheckedBytes.sum
            let future = try sum([remaining, inventory.constructionBytes,
                inventory.largestTensorBytes, inventory.largestTensorBytes,
                CheckpointAlignedReadPlan.maximumScratchAllocationBytes, remainingResidentAllowanceBytes])
            let hostNeed = try sum([future, QwenDenseStageLoadPolicy.loadingHeadroomBytes])
            let nativeNeed = try sum([Memory.activeMemory, Memory.cacheMemory, future,
                QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
            guard try watch.admits(QwenDenseStageLoadResources.observeOS(), bytes: hostNeed),
                  Memory.memoryLimit >= nativeNeed else {
                throw ProbeError("Qwen TP assistant exceeds native/host LOAD limits")
            }
        }
        do {
            try MLX.withError { error in
                try gate(); try checkpoint.bypassTensorPayloadCache()
                for entry in inventory.entries {
                    try gate()
                    let descriptor = entry.descriptor, value = try descriptor.read(.all)
                    guard value.copiedBytes == descriptor.byteCount,
                          value.readAccounting?.selectedBytes == descriptor.byteCount else {
                        throw ProbeError("Qwen TP assistant payload custody is incomplete")
                    }
                    let array = value.array
                    // Retain before evaluating so a native fault cannot let a
                    // failed read escape its outstanding LOAD reservation.
                    custody.weights[entry.name] = array
                    eval(array); Stream.gpu.synchronize(); Stream.cpu.synchronize()
                    try error.check(); try check()
                    guard array.shape == descriptor.shape, array.dtype == descriptor.dtype,
                          array.nbytes == descriptor.byteCount,
                          let info = try array.evaluatedBufferInfo(), info.isUnique, info.dataOffset == 0,
                          info.isRowContiguous, info.dataElements == array.size,
                          info.allocatedBytes >= array.nbytes,
                          info.allocatedBytes <= (try Memory.allocationFootprintUpperBound(byteCount: array.nbytes)) else {
                        throw ProbeError("Qwen TP assistant tensor is not an owned exact allocation")
                    }
                    remaining -= try Memory.allocationFootprintUpperBound(byteCount: descriptor.byteCount)
                }
                guard remaining == 0, custody.weights.count == inventory.entries.count else {
                    throw ProbeError("Qwen TP assistant LOAD did not finish")
                }
                try gate()
                custody.head = try QwenTensorParallelMTPHead(model: target, configuration: configuration,
                    indexedWeights: custody.weights, reduction: reduction,
                    retainDuringLoad: { custody.assistant = $0 })
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                try error.check(); try checkpoint.checkUnchanged(); try check()
            }
            return custody.head!
        } catch { throw QwenTensorParallelMTPLoadFailure(error, custody: custody) }
    }
}
