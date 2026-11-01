import DarkbloomClusterProtocol
import Foundation
import MLX

extension GPTOSSResidentRuntime {
    private func batchWorkspace() throws -> GPTOSSBatchWorkspace {
        try .estimate(spec: admission.specification, localLayers: admission.plan.stages[collective.rank].layers.count,
            rank: collective.rank, lanes: batchLanes, bound: QwenResidentResourceEnvironment.allocationBound)
    }

    public func reserveLane(requestID: UUID, request value: ClusterWorkerReservation) throws -> Int {
        try withBatchOperation {
            guard batchLanes > 1, generationMode == .pipeline, stage != nil, laneBook.count < batchLanes else {
                throw ProbeError("GPT-OSS batch lanes are unavailable or full")
            }
            let request = try admission.request(value, id: requestID, now: DispatchTime.now().uptimeNanoseconds)
            guard !request.decodingRankAlone else { throw ProbeError("GPT-OSS batches require both pipeline ranks") }
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            let allowance = try GPTOSSResidentRequestAllowance.derive(plan: admission.plan, rank: collective.rank,
                maximumTokens: request.maximumTokens, chunkSize: min(request.chunkSize, request.promptCount))
            let prefill = try prefillAllowance(servingPolicy, promptCount: request.promptCount, chunkSize: request.chunkSize)
            let reserved = try GPTOSSBatchReservation(request: request, allowance: allowance,
                deadline: value.deadlineUptimeNanoseconds, prefillAllowance: prefill)
            guard reserved.laneStateBytes <= value.capacityLimitBytes,
                  reserved.laneStateBytes <= baseReady.requestCapacityBytes else {
                throw ProbeError("GPT-OSS batch reservation exceeds its owner ceiling")
            }
            let workspace = try batchWorkspace()
            let held = laneBook.reservations()
            try allowance.requireLive(additionalNativeBytes: QwenLongPrefillCheckedBytes.sum(
                held.map(\.nativeBytes) + [prefill?.extraNativeBytes ?? 0, workspace.native]),
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
                throw ProbeError("GPT-OSS batch owner is unavailable")
            }
            batchServing = true; defer { batchServing = false }
            let scope = UUID(), workspace = try batchWorkspace()
            do {
                batchRecordOrdinal = try QwenBatchRecordBinding.nextOrdinal(after: batchRecordOrdinal)
                let records = try QwenBatchRecordBinding(epoch: admission.configuration.identity.membershipEpoch,
                    planFingerprint: admission.plan.fingerprint, ordinal: batchRecordOrdinal, lanes: batchLanes)
                try lifecycle.withRequest(identity: .init(requestID: scope, epoch: scope,
                    recordedRequestFingerprint: sha256(Data("gptoss-batch-scope-v1|\(scope.uuidString)".utf8)))) {
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
                                        QwenLongPrefillCheckedBytes.sum([others, first.prefillAllowance?.extraNativeBytes ?? 0, workspace.native]),
                                        additionalHostBytes: QwenLongPrefillCheckedBytes.sum(values.map(\.hostBytes) + [workspace.host]))
                                }
                                lastCheck = now
                            }
                            try nativeError.check()
                        }
                        let native = GPTOSSNativeBatchExecutor(stage: stage, admission: admission, collective: collective,
                            records: records, capacity: batchLanes, check: checked)
                        let driver = try GPTOSSBatchDriver(rank: collective.rank, capacity: batchLanes,
                            vocabulary: admission.profile.vocabularySize, book: laneBook, executor: native)
                        batchDriver = driver
                        try driver.serve(host: host, check: checked)
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
