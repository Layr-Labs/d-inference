import DarkbloomClusterProtocol
import Foundation
import MLX

extension MiMoResidentRuntime {
    private func batchWorkspace() throws -> MiMoBatchMemory.Workspace {
        try MiMoBatchMemory.workspace(spec: admission.specification, localLayers: admission.plan.stages[collective.rank].layers.count,
            rank: collective.rank, lanes: batchLanes, bound: QwenResidentResourceEnvironment.allocationBound)
    }

    public func reserveLane(requestID: UUID, request value: ClusterWorkerReservation) throws -> Int {
        try withBatchOperation {
            guard batchLanes > 1, generationMode == .pipeline, stage != nil, laneBook.count < batchLanes else {
                throw ProbeError("MiMo batch lanes are unavailable or full")
            }
            let request = try admission.request(value, id: requestID, now: DispatchTime.now().uptimeNanoseconds)
            guard !request.decodingRankAlone, request.mimoImages == nil else { throw ProbeError("MiMo batches require both pipeline ranks") }
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            let allowance = try MiMoResidentRequestAllowance.derive(specification: admission.specification,
                plan: admission.plan, rank: collective.rank, maximumTokens: request.maximumTokens,
                chunkSize: min(request.chunkSize, request.promptCount), independentHistory: true)
            let reserved = try MiMoBatchReservation(request: request, allowance: allowance,
                deadline: value.deadlineUptimeNanoseconds, pageBytes: allowance.pagedBytes)
            guard reserved.laneStateBytes <= value.capacityLimitBytes,
                  reserved.laneStateBytes <= baseReady.requestCapacityBytes else {
                throw ProbeError("MiMo batch reservation exceeds its owner ceiling")
            }
            let workspace = try batchWorkspace()
            let held = laneBook.reservations()
            try allowance.requireLive(additionalNativeBytes: QwenLongPrefillCheckedBytes.sum(
                held.map(\.nativeBytes) + [workspace.native]),
                additionalHostBytes: QwenLongPrefillCheckedBytes.sum(held.map(\.hostBytes)
                    + [reserved.hostBytes, workspace.host]))
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            try laneBook.reserve(requestID, reserved, lanes: batchLanes)
            return reserved.laneStateBytes
        }
    }
    public func startLane(requestID: UUID) throws { try laneBook.start(requestID) }
    public func cancelLane(requestID: UUID) { laneBook.cancel(requestID) }
    public func withdrawLane(requestID: UUID) -> Bool { laneBook.withdraw(requestID) }
    public var hasStartedLanes: Bool { laneBook.hasStarted }

    public func serveBatch(host: QwenBatchServingHost) throws {
        try withBatchOperation {
            guard batchLanes > 1, generationMode == .pipeline, let stage, batchDriver == nil else {
                throw ProbeError("MiMo batch owner is unavailable")
            }
            batchServing = true; defer { batchServing = false }
            let scope = UUID(), workspace = try batchWorkspace()
            do {
                batchRecordOrdinal = try QwenBatchRecordBinding.nextOrdinal(after: batchRecordOrdinal)
                let records = try QwenBatchRecordBinding(epoch: admission.configuration.identity.membershipEpoch,
                    planFingerprint: admission.plan.fingerprint, ordinal: batchRecordOrdinal, lanes: batchLanes)
                try lifecycle.withRequest(identity: .init(requestID: scope, epoch: scope,
                    recordedRequestFingerprint: sha256(Data("mimo-batch-scope-v1|\(scope.uuidString)".utf8)))) {
                    try MLX.withError { nativeError in
                        var lastCheck: UInt64 = 0
                        let book = laneBook, control = control
                        func checked() throws {
                            try nativeError.check(); try control.check()
                            let now = DispatchTime.now().uptimeNanoseconds
                            if lastCheck == 0 || now - lastCheck >= 250_000_000 {
                                let values = book.reservations()
                                if let first = values.first {
                                    let others = try QwenLongPrefillCheckedBytes.sum(values.dropFirst().map(\.nativeBytes))
                                    try first.allowance.requireLive(additionalNativeBytes:
                                        QwenLongPrefillCheckedBytes.sum([others, workspace.native]),
                                        additionalHostBytes: QwenLongPrefillCheckedBytes.sum(values.map(\.hostBytes) + [workspace.host]))
                                }
                                lastCheck = now
                            }
                            try nativeError.check()
                        }
                        let native = MiMoNativeBatchExecutor(stage: stage, admission: admission, collective: collective,
                            records: records, capacity: batchLanes, check: checked)
                        let driver = try IndependentHistoryBatchDriver(rank: collective.rank, capacity: batchLanes,
                            vocabulary: admission.profile.vocabularySize, book: laneBook, executor: native)
                        batchDriver = driver
                        try driver.serve(host: host, check: checked)
                        // serve returns only after each native session retired;
                        // the lane ledger is observed separately from page bytes.
                        log("darkbloom-mimo-batch-memory-v1 rank=\(collective.rank) scope=\(records.requestID.uuidString)"
                            + " phase=drained reserved_bytes=\(try book.stateBytes()) lanes_in_use=\(book.count)")
                        batchDriver = nil
                    }
                }
            } catch {
                control.fail()
                throw error
            }
        }
    }
}
