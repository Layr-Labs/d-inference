import Foundation

/// A single-use selected-tensor gate. Pure observation checks are separately
/// testable; resident loading always calls requireLive(), which samples the host.
final class GLM5NextStageLoadGate {
    let resources: GLM5NextStageLoadResources
    let capacityLimitBytes: Int
    let executionStateReserveBytes: Int
    let workspaceReserveBytes: Int
    let reservedBytes: Int
    private(set) var remainingAllocationBytes: Int
    private(set) var requestedNames: Set<String> = []
    private(set) var requestedBytes = 0
    private(set) var isFailed = false
    private(set) var isComplete = false
    private(set) var lastAdmission: QwenDenseStageLoadAdmission?
    private(set) var lastNativeObservation: QwenDenseStageLoadNativeObservation?
    /// The families' shared host-memory watch: the same policy, its file-cache
    /// reclaim when uncounted cache is the only shortfall, and the explicit
    /// qualification-only measuring mode (off in every installed process).
    private let watch = QwenDenseStageLoadWatch("GLM selected-stage resident load")
    private var inFlightAllocationBytes = 0
    private var operationCheck: (() throws -> Void)?

    init(resources: GLM5NextStageLoadResources, capacityLimitBytes: Int,
         executionStateReserveBytes: Int, workspaceReserveBytes: Int) throws {
        guard executionStateReserveBytes > 0, workspaceReserveBytes > 0, capacityLimitBytes > 0 else {
            throw ProbeError("GLM resident loading requires explicit positive state/workspace reservations")
        }
        let reserved = try GLM5NextStageLoadResources.sum([
            resources.summary.initialLoadPeakBytes, executionStateReserveBytes, workspaceReserveBytes])
        guard reserved <= capacityLimitBytes else {
            throw ProbeError("GLM selected-stage LOAD quotation exceeds its capacity reservation")
        }
        self.resources = resources; self.capacityLimitBytes = capacityLimitBytes
        self.executionStateReserveBytes = executionStateReserveBytes
        self.workspaceReserveBytes = workspaceReserveBytes
        self.reservedBytes = reserved
        remainingAllocationBytes = resources.summary.sourceAllocationBoundBytes
    }

    /// Installed only for the synchronous load. Always clear it on return so a
    /// caller-capturing closure cannot keep an otherwise retired owner alive.
    func beginOperation(check: @escaping () throws -> Void) throws {
        guard operationCheck == nil, !isFailed, !isComplete else {
            throw ProbeError("GLM load check requires a fresh inactive gate")
        }
        operationCheck = check
    }

    func endOperation() { operationCheck = nil }

    func requireOperation() throws {
        do {
            guard !isFailed, let operationCheck else {
                throw ProbeError("GLM load operation is inactive or failed")
            }
            try Task.checkCancellation()
            try operationCheck()
        } catch { isFailed = true; throw error }
    }

    func requireLive() throws {
        do {
            try requireOperation()
            try require(os: QwenDenseStageLoadResources.observeOS(),
                native: QwenDenseStageLoadResources.observeNative(),
                now: DispatchTime.now().uptimeNanoseconds)
            try requireOperation()
        } catch { isFailed = true; throw error }
    }

    /// No caller-supplied observation is accepted by the resident load API.
    func require(os: QwenDenseStageLoadOSObservation, native: QwenDenseStageLoadNativeObservation,
                 now: UInt64) throws {
        do {
            guard !isFailed, native.activeBytes >= 0, native.cacheBytes >= 0,
                  native.allocatorLimitBytes > 0 else { throw ProbeError("GLM load gate is failed or unbounded") }
            let summary = resources.summary
            let nativeScratch = isComplete ? 0 : summary.nativeConstructionAllowanceBytes
            let hostScratch = isComplete ? 0 : summary.hostReadAllowanceBytes
            let additional = try GLM5NextStageLoadResources.sum([
                remainingAllocationBytes, inFlightAllocationBytes, nativeScratch,
                executionStateReserveBytes, workspaceReserveBytes])
            let free = try GLM5NextStageLoadResources.sum([additional, hostScratch,
                summary.metadataAllowanceBytes,
                QwenDenseStageLoadPolicy.loadingHeadroomBytes(physicalMemoryBytes: os.physicalMemoryBytes)])
            let allocator = try GLM5NextStageLoadResources.sum([native.activeBytes, native.cacheBytes,
                additional, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
            _ = try watch.admits(os, bytes: free, now: now)
            lastAdmission = watch.summary.latest
            guard allocator <= native.allocatorLimitBytes else {
                throw ProbeError("GLM selected-stage load exceeds the live allocator limit")
            }
            lastNativeObservation = native
        } catch { isFailed = true; throw error }
    }

    func beforeRead(_ name: String, bytes: Int, check: () throws -> Void) throws {
        do {
            try validateNext(name, bytes: bytes)
            // A new SDK callback proves the previous read returned. During
            // evaluation of the current read, still price its full allocation:
            // a lazy array need not appear in native active bytes yet.
            inFlightAllocationBytes = 0
            try check()
            try requireLive()
            try recordRequest(name, bytes: bytes)
        } catch { isFailed = true; throw error }
    }

    /// Metadata progress, not successful-read evidence. The SDK's consumed set
    /// and unchanged source are checked before a resident receipt is published.
    func recordRequest(_ name: String, bytes: Int) throws {
        do {
            try validateNext(name, bytes: bytes)
            let tensor = resources.selected[name]!
            guard tensor.allocationBound <= remainingAllocationBytes else {
                throw ProbeError("GLM remaining allocation accounting underflow")
            }
            requestedBytes = try GLM5NextStageLoadResources.sum([requestedBytes, bytes])
            requestedNames.insert(name)
            remainingAllocationBytes -= tensor.allocationBound
            inFlightAllocationBytes = tensor.allocationBound
        } catch { isFailed = true; throw error }
    }

    func finish() throws {
        do {
            guard !isFailed, !isComplete, remainingAllocationBytes == 0,
                  requestedNames.count == resources.selected.count,
                  requestedBytes == resources.summary.selectedStoredBytes else {
                throw ProbeError("GLM selected-stage payload reads are incomplete")
            }
            inFlightAllocationBytes = 0
            isComplete = true
            try requireLive()
        } catch { isFailed = true; throw error }
    }

    private func validateNext(_ name: String, bytes: Int) throws {
        guard !isFailed, !isComplete, let expected = resources.selected[name],
              expected.bytes == bytes, !requestedNames.contains(name) else {
            throw ProbeError("GLM load read is duplicated, foreign or differs from admitted bytes")
        }
    }
}
