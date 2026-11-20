import DarkbloomClusterProtocol
import Foundation

extension QwenTensorParallelStopRule.End {
    /// The memory abort both ranks end the request with (D6), naming the refusing rank.
    var abort: ClusterWorkerAbort? { memoryStopRank.map { ClusterWorkerAbort(reason: .memory, rank: $0) } }
}

/// The live memory gates the families without one of their own take while a
/// request is reserved and while it runs. Each has the one shape every running
/// gate has: power and thermal first (untyped: those still fail the worker),
/// then memory, judged only inside the typed block, so every memory refusal is
/// a `QwenResidentMemoryRefusal` and a running request's stop latch, stop slot
/// or lane ends that request alone. Each asks at least the entry check's floor
/// on its own sample, so the entry check (`QwenResidentResourceEnvironment.require`)
/// is not asked first: it would refuse untyped.
enum ClusterLiveMemory {
    /// The tensor-parallel families' gate for `bytes` more (Gemma 4, GLM and MiMo V2.6).
    static func requireTensorParallel(bytes: Int, family: String) throws {
        try QwenResidentResourceEnvironment.requirePower()
        let watch = QwenDenseStageLoadWatch("\(family) tensor-parallel")
        let os = try QwenDenseStageLoadResources.observeOS()
        let free = try QwenDenseStageLoadPolicy.tensorParallelRequiredBytes(bytes,
            physicalMemoryBytes: QwenDenseStageLoadPolicy.localPhysicalMemoryBytes)
        do {
            guard try watch.admits(os, bytes: free) else {
                throw ProbeError("\(family) tensor parallel needs \(bytes) bytes the memory gate does not admit now")
            }
        } catch {
            throw QwenResidentMemoryRefusal(message: String(describing: error))
        }
    }

    /// A pipeline stage's gate for one request (MiMo V2.6's and GPT-OSS's
    /// stages), at that request's own `watch`: its `reservedBytes` plus the
    /// loading headroom and `additionalNativeBytes` (its prompt-prefix
    /// capture) and `additionalHostBytes` must be admissible, and the allocator
    /// limit must cover what is resident plus the allowance and the capture.
    static func requireStageRequest(_ watch: QwenDenseStageLoadWatch, reservedBytes: Int, additionalNativeBytes: Int,
                                    additionalHostBytes: Int, family: String) throws {
        try QwenResidentResourceEnvironment.requirePower()
        let os = try QwenDenseStageLoadResources.observeOS()
        let native = QwenDenseStageLoadResources.observeNative()
        let free = max(QwenDenseStageLoadPolicy.minimumAdmissibleBytes,
            try QwenLongPrefillCheckedBytes.sum([reservedBytes, additionalNativeBytes, additionalHostBytes,
                QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
        let allocator = try QwenLongPrefillCheckedBytes.sum([native.activeBytes, native.cacheBytes, reservedBytes,
            additionalNativeBytes, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
        do {
            guard try watch.admits(os, bytes: free) else { throw ProbeError("Resident \(family) request was refused") }
            guard native.allocatorLimitBytes >= allocator else {
                throw ProbeError("Resident \(family) request exceeds the allocator limit")
            }
        } catch {
            throw QwenResidentMemoryRefusal(message: String(describing: error))
        }
    }
}
