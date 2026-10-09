import CryptoKit
import DarkbloomClusterProtocol
import Darwin
import Foundation
import MLX
import MLXNN

/// SHA-256 over every resident parameter of a model, in name order: each name,
/// dtype and shape, then the parameter's bytes as they sit in memory. Two loads
/// with equal digests hold the same weights, placeholders included.
func qwenStageParameterDigest(_ model: Module) -> String {
    var hash = SHA256()
    for (name, array) in model.parameters().flattened().sorted(by: { $0.0 < $1.0 }) {
        hash.update(data: Data("\(name)|\(array.dtype)|\(array.shape)\n".utf8))
        hash.update(data: array.asData(access: .noCopyIfContiguous).data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

/// This process's physical footprint as the kernel accounts it, or 0 if it cannot be read.
private func qwenProcessFootprintBytes() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS && info.phys_footprint <= UInt64(Int.max) ? Int(info.phys_footprint) : 0
}

/// One Mac, one rank, the real artifact, no collective: loads the rank's stage
/// from local files, then again as a receiving rank would get it. The second
/// load takes its metadata from the pinned content inventory and its bytes
/// from a sender core over this Mac's verified artifact, in this process and
/// on one thread, through the native intake. It shows byte equality with the
/// local load, the peak, the release and the cost of hashing on this chip.
/// It shows nothing about RDMA, the link, two processes or failure timing.
public enum QwenResidentStageTransferCheck {
    public enum Fault: String, Sendable {
        case flippedBit = "flipped-bit", swappedTensors = "swapped-tensors", truncatedPiece = "truncated-piece"

        /// What the receiving side must say when it refuses this fault.
        var refusal: String {
            switch self {
            case .flippedBit, .swappedTensors: "Stage tensor content differs from its pinned SHA-256"
            case .truncatedPiece: "Stage transfer piece differs from its planned shape, dtype or size"
            }
        }
    }

    public struct Load: Encodable, Sendable {
        public let storageCommitmentSHA256: String
        public let parameterSHA256: String
        /// From the start of the load to a ready stage model.
        public let seconds: Double
        /// The largest MLX active memory during the load, above what was active before it.
        public let peakBytes: Int
        public let loadedBytes: Int
        /// The largest active plus cached MLX memory at any check the load made, above what was
        /// active before it. A load checks about once per piece and several times per tensor.
        public let sampledActiveAndCachePeakBytes: Int
        /// This process's footprint before the load, and the largest at any of those checks.
        public let footprintBeforeBytes: Int
        public let sampledFootprintPeakBytes: Int
        /// How often this load asked the host memory gate.
        public let resourceDecisions: Int
    }

    public struct Receipt: Encodable, Sendable {
        public let schema = "qwen_resident_stage_transfer_check_v1"
        public let rank: Int
        public let stageCut: Int
        public let fault: String?
        /// The local load; absent when a fault is injected.
        public let local: Load?
        /// The transferred load; absent when it was refused.
        public let transferred: Load?
        public let refusal: String?
        public let matchesLocalLoad: Bool?
        /// Verifying the sending side's artifact, which on a pair the leader does before it serves.
        public let senderVerifySeconds: Double
        /// From the open exchange to a verified intake: reads, pieces, joins and hashing.
        public let transferSeconds: Double?
        public let tensorCount: Int
        public let payloadBytes: Int
        public let pieceCount: Int
        public let windowCount: Int
        public let largestTensorBytes: Int
        public let pieceByteLimit: Int
        public let windowByteLimit: Int
        public let hashThreadCount: Int
        /// Loaded bytes plus twice the largest tensor plus one window. The transferred load's
        /// active peak and its sampled active plus cached memory must both stay within it.
        public let peakBoundBytes: Int?
        public let peakWithinBound: Bool?
        public let metadataFileCount: Int
        public let metadataBytes: Int
        public let activeBytesAfterRelease: Int
        public let cacheBytesAfterRelease: Int
        public let modelsReleased: Bool
        /// What the host memory gate decided in this process, over both loads.
        public let resourceAdmission: QwenDenseStageLoadAdmissionSummary
        public let passed: Bool
        public let collectiveCreated = false
    }

    public static func run(modelDirectory: URL, rank: Int, stageCut: Int, deadlineUptimeNanoseconds: UInt64,
                           hashThreads requested: Int? = nil, fault: Fault? = nil) throws -> Receipt {
        let hashThreads = requested ?? QwenStageNativeIntake.hashThreadCount
        guard (1...16).contains(hashThreads) else { throw ProbeError("Stage transfer check takes 1 to 16 hashing threads") }
        let admission = try QwenResidentStageLoadCheck.admit(modelDirectory: modelDirectory, rank: rank,
            stageCut: stageCut, deadlineUptimeNanoseconds: deadlineUptimeNanoseconds)
        let inventory = try QwenRegisteredContentInventory.require(admission.specification)
        let control = QwenResidentControl(deadline: deadlineUptimeNanoseconds)
        try QwenResidentProcessLease.shared.acquire()
        defer { QwenResidentProcessLease.shared.release() }
        try control.check()
        try QwenResidentResourceEnvironment.require()
        func uptime() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

        return try MLX.withError { nativeError in
            var sampledNative = 0, sampledFootprint = 0
            func checked() throws {
                try nativeError.check(); try control.check()
                let memory = Memory.snapshot()
                sampledNative = max(sampledNative, memory.activeMemory + memory.cacheMemory)
                sampledFootprint = max(sampledFootprint, qwenProcessFootprintBytes())
                try nativeError.check()
            }
            func settle() throws {
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                try nativeError.check()
            }
            var released = true
            /// Loads, measures, digests and releases one stage; on a refusal it releases and rethrows.
            func measure(_ load: () throws -> QwenResidentLoadedStage) throws -> Load {
                try settle()
                GPU.resetPeakMemory()
                let before = Memory.snapshot().activeMemory, footprintBefore = qwenProcessFootprintBytes()
                sampledNative = 0; sampledFootprint = 0
                let started = uptime(), asked = QwenDenseStageLoadAdmissionSummary.current.decisions
                var stage: QwenResidentLoadedStage?
                weak var retired: Module?
                do {
                    try autoreleasepool {
                        let value = try load()
                        retired = value.loaded.model; stage = value
                    }
                    try settle()
                    let seconds = Double(uptime() - started) / 1e9
                    let memory = Memory.snapshot()
                    // Plain values only: a second reference to the stage would keep the model past the release below.
                    guard let commitment = stage?.loaded.receipt.storageCommitmentSHA256,
                          let parameters = (stage?.loaded.model).map(qwenStageParameterDigest) else {
                        throw ProbeError("Stage loader returned no stage")
                    }
                    let result = Load(storageCommitmentSHA256: commitment, parameterSHA256: parameters, seconds: seconds,
                        peakBytes: memory.peakMemory - before, loadedBytes: memory.activeMemory - before,
                        sampledActiveAndCachePeakBytes: max(0, sampledNative - before),
                        footprintBeforeBytes: footprintBefore, sampledFootprintPeakBytes: sampledFootprint,
                        resourceDecisions: QwenDenseStageLoadAdmissionSummary.current.decisions - asked)
                    stage = nil
                    try settle(); Memory.clearCache(); try settle()
                    released = released && retired == nil
                    return result
                } catch {
                    let primary = error
                    stage = nil
                    Stream.gpu.synchronize(); Stream.cpu.synchronize()
                    Memory.clearCache()
                    released = released && retired == nil
                    try nativeError.check()
                    throw primary
                }
            }

            // With a fault there is nothing to compare: only the refusal and the release matter.
            let local: Load? = fault == nil ? try measure { try loadQwenResidentStage(admission, check: checked) } : nil
            let metadata = try QwenResidentMetadataFiles.verify(admission)
            let verifyStarted = uptime()
            let checkpoint = try VerifiedCheckpoint(directory: modelDirectory, configurationData: admission.configBytes,
                expectedAggregateSHA256: admission.specification.artifactSHA256,
                maximumPayloadBytes: QwenResidentResourceCeilings(specification: admission.specification).maximumManifestPayloadBytes,
                expectedManifestSHA256: admission.specification.manifestSHA256)
            try checkpoint.bypassTensorPayloadCache()
            let verifySeconds = Double(uptime() - verifyStarted) / 1e9

            var plan: QwenStageTransferPlan?, transferSeconds: Double?
            var transferred: Load?, refusal: String?
            do {
                transferred = try measure {
                    let pinned = try prepareQwenResidentPinnedSource(admission, check: checked)
                    let payload = QwenStageTransferredPayload { active, gate in
                        let framing = try QwenStageTransferPlan(stages: [.init(stageIndex: rank, active: active)], limits: .proposed)
                        let session = try QwenStageTransferSession(
                            loadAgreementFingerprint: admission.loadAgreementFingerprint(), plan: framing, inventory: inventory)
                        plan = framing
                        let source = QwenStageCheckpointByteSource(checkpoint: checkpoint)
                        let watch = {
                            QwenStageTransferWatch(deadlines: .init(lifetimeUptimeNanoseconds: deadlineUptimeNanoseconds,
                                startupUptimeNanoseconds: nil, progressTimeoutNanoseconds: 60_000_000_000),
                                now: uptime, check: { try control.check(deadline: $0) })
                        }
                        func receive<Source: QwenStageTransferByteSource>(from source: Source) throws -> QwenStageNativeIntake
                        where Source.Payload == MLXArray {
                            let started = uptime()
                            let intake = try runQwenStageTransferInProcess(session: session, source: source,
                                active: active, gate: gate, hashThreads: hashThreads, watch: watch, check: checked)
                            transferSeconds = Double(uptime() - started) / 1e9
                            return intake
                        }
                        guard let fault else { return try receive(from: source) }
                        return try receive(from: QwenStageFaultyByteSource(source: source, fault: try injected(fault, session)))
                    }
                    return try loadQwenResidentStage(admission, source: pinned, payload: payload, check: checked)
                }
            } catch {
                // Only the refusal this fault must cause counts; anything else is the check failing.
                guard let fault, String(describing: error).contains(fault.refusal) else { throw error }
                refusal = String(describing: error)
            }
            try checkpoint.checkUnchanged()
            try settle()
            let after = Memory.snapshot()
            guard let plan else { throw ProbeError("Stage transfer was refused before it was planned: \(refusal ?? "")") }
            let largest = plan.tensors.map(\.byteCount).max() ?? 0
            let bound = transferred.map { $0.loadedBytes + 2 * largest + plan.limits.windowByteLimit }
            let matches = transferred.flatMap { received in
                local.map { $0.storageCommitmentSHA256 == received.storageCommitmentSHA256 && $0.parameterSHA256 == received.parameterSHA256 }
            }
            let within = transferred.flatMap { received in
                bound.map { max(received.peakBytes, received.sampledActiveAndCachePeakBytes) <= $0 }
            }
            // A few KB of allocator bookkeeping stay active after the existing stage check too.
            let baseline = after.activeMemory < 1_048_576 && after.cacheMemory == 0 && released
            return Receipt(rank: rank, stageCut: stageCut, fault: fault?.rawValue, local: local, transferred: transferred,
                refusal: refusal, matchesLocalLoad: matches, senderVerifySeconds: verifySeconds,
                transferSeconds: transferSeconds, tensorCount: plan.tensors.count, payloadBytes: plan.payloadBytes,
                pieceCount: plan.pieces.count, windowCount: plan.windows.count, largestTensorBytes: largest,
                pieceByteLimit: plan.limits.pieceByteLimit, windowByteLimit: plan.limits.windowByteLimit,
                hashThreadCount: hashThreads, peakBoundBytes: bound, peakWithinBound: within,
                metadataFileCount: metadata.fileCount, metadataBytes: metadata.byteCount,
                activeBytesAfterRelease: after.activeMemory, cacheBytesAfterRelease: after.cacheMemory,
                modelsReleased: released, resourceAdmission: .current,
                passed: baseline && (fault == nil ? matches == true && within == true : refusal != nil && transferred == nil))
        }
    }

    /// Where in this transfer the fault lands: a piece near the middle, or two
    /// one-piece tensors of one shape and dtype whose pinned contents differ.
    private static func injected(_ fault: Fault, _ session: QwenStageTransferSession) throws -> QwenStageFaultyByteSource.Fault {
        let plan = session.plan, middle = plan.pieces.count / 2
        switch fault {
        case .flippedBit: return .flippedBit(piece: middle)
        case .truncatedPiece:
            guard let piece = plan.pieces[middle...].first(where: { $0.shape[0] > 1 }) else {
                throw ProbeError("No piece of more than one row to truncate")
            }
            return .truncated(piece: piece.index)
        case .swappedTensors:
            let single = plan.tensors.indices.filter { plan.tensors[$0].pieces.count == 1 }
            for a in single {
                guard let b = single.first(where: { $0 > a && plan.tensors[$0].shape == plan.tensors[a].shape
                    && plan.tensors[$0].dtype == plan.tensors[a].dtype
                    && session.records[$0].contentSHA256 != session.records[a].contentSHA256 }) else { continue }
                let first = session.records[a].source, second = session.records[b].source
                return .substituted([
                    "\(first.sourceFile)|\(first.sourceOffset)": (second.sourceFile, second.sourceOffset),
                    "\(second.sourceFile)|\(second.sourceOffset)": (first.sourceFile, first.sourceOffset),
                ])
            }
            throw ProbeError("No two same-shape tensors with different contents to swap")
        }
    }
}
