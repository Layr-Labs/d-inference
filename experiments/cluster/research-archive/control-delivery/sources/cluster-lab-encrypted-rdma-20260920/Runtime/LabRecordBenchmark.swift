import CryptoKit
import DarkbloomClusterSecurity
import Darwin
import Foundation
import MLX

struct LabRecordReport: Encodable {
    let schema = "lab_authenticated_rdma_report_v1"
    let job: LabRecordJob, scopeSHA256: String
    let codec: [LabCodecSample], copies: [LabCopySample], transfers: [LabTransferSample]
    let sealedRecords: UInt64, openedRecords: UInt64, sealedBytes: UInt64, openedBytes: UInt64
    let baselineNativeBytes: Int, finalNativeBytes: Int, maximumObservedNativeBytes: Int
    let baselinePhysical: LabRecordFootprint, finalPhysical: LabRecordFootprint
    let minimumObservedFreeBytes: Int, resourceObservations: Int
    let collectiveReleased = true, nativeCacheBytesAfterRelease = 0
    let labOnly = true, productMembershipEstablished = false, productRuntimeApproved = false
    let modelExecuted = false, externalHTTPTTFTMeasured = false, processOrLeaseRetirementEstablished = false
    let keyMaterialExported = false, recordCodecChanged = false, nativeCopyCodeChanged = false
    let operationTimingsIncludeExistingChecks = true
    let rank0RoundtripIsSameClock = true, rank1ReceiveIncludesPeerWait = true
}

@_spi(ClusterTesting) public enum LabAuthenticatedRDMABenchmark {
    public static func run(arguments: [String]) throws -> Data {
        if arguments == ["--check-local"] { return try LabRecordChecks.run() }
        guard arguments.count == 2, ["--describe", "--check-arguments", "--execute"].contains(arguments[0]) else {
            throw ProbeError("Use --describe|--check-arguments|--execute LAB-JOB")
        }
        let job = try LabRecordJob.decode(BoundedProbeInput.data(URL(fileURLWithPath: arguments[1]), maximumBytes: 16_384))
        if arguments[0] != "--execute" {
            return try JSONSerialization.data(withJSONObject: [
                "schema": "lab_authenticated_rdma_description_v1", "scopeSHA256": job.scopeSHA256,
                "payloadBytes": job.payloadBytes, "frameCeiling": job.frameCeiling,
                "modes": LabRecordJob.modes, "warmups": 3, "measurements": 20,
                "maximumRecordsPerDirection": 64, "nativeAllowanceBytes": LabRecordResources.nativeAllowance,
                "processAllowanceBytes": LabRecordResources.hostAllowance,
                "minimumActualFreeBytes": LabRecordResources.minimumFree + LabRecordResources.hostAllowance,
                "requiresAC": true, "pressureLevel": 1, "maximumSwapBytes": 0,
                "labOnly": true, "productMembershipEstablished": false, "productRuntimeApproved": false,
                "metadataOnly": true, "nativeExecuted": false], options: [.sortedKeys, .withoutEscapingSlashes])
        }
        alarm(UInt32(job.timeoutSeconds))
        let key = try job.secretFromStdin()
        return try MLX.withError { native in
            try QwenResidentResourceEnvironment.require()
            Memory.cacheLimit = 0
            Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache(); try native.check()
            Memory.peakMemory = 0
            let resources = try LabRecordResources(job: job)
            func check() throws { try native.check(); try resources.check(); try native.check() }
            weak var releasedGroup: Collective?
            let result: ([LabCodecSample], [LabCopySample], [LabTransferSample], ClusterRecordStatus) = try autoreleasepool {
                let plaintext = Data(repeating: 0x59, count: job.payloadBytes)
                let codec = try LabRecordMeasurements.codec(job, key: key, plaintext: plaintext, check: check)
                let copies = try LabRecordMeasurements.copies(job, plaintext: plaintext, check: check)
                try check()
                let group = try Collective(transport: .jaccl); releasedGroup = group
                guard group.rank == job.rank, group.size == 2 else { throw ProbeError("Lab actual RDMA rank differs") }
                let io = try CollectiveRecordByteIO(endpoint: LabCiphertextEndpoint(group), maximumFrameBytes: job.frameCeiling)
                let timed = LabTimedRecordIO(io)
                let limits = try ClusterRecordLimits(maximumPlaintextBytes: job.plaintextCeiling,
                    maximumRecordsPerDirection: 64,
                    maximumCumulativePlaintextBytesPerDirection: UInt64(job.payloadBytes * job.rounds * 2 + 32))
                let records = try ClusterAuthenticatedRecordTransport(sessionKey: key,
                    binding: LabRecordMeasurements.recordBinding(job, "actual-wire"), limits: limits, io: timed)
                let arrays = try CollectiveAuthenticatedRecords(io: io, transport: records)
                defer { arrays.invalidate(); records.invalidate(); timed.discard() }
                let confirmation = Data(SHA256.hash(data: Data(("lab-confirm/" + job.scopeSHA256).utf8)))
                let expected = try ClusterRecordTransferExpectation(
                    context: LabRecordMeasurements.context(job, "mutual-confirmation"), length: .exact(32))
                let peer: Data
                if job.rank == 0 {
                    try records.send(confirmation, expecting: expected, check: check)
                    peer = try records.receive(expecting: expected, check: check)
                } else {
                    peer = try records.receive(expecting: expected, check: check)
                    try records.send(confirmation, expecting: expected, check: check)
                }
                guard peer == confirmation else { throw ProbeError("Lab transcript/key confirmation differs") }
                _ = try timed.take()
                var samples = [LabTransferSample]()
                for mode in LabRecordJob.modes {
                    for ordinal in 0..<job.rounds {
                        let sample = try autoreleasepool {
                            try LabRecordMeasurements.transfer(job: job, mode: mode, ordinal: ordinal, plaintext: plaintext,
                                io: timed, records: records, arrays: arrays, check: check)
                        }
                        samples.append(sample); try check()
                    }
                }
                let status = records.status.codec
                let expectedCount = UInt64(1 + job.rounds * 2), expectedBytes = UInt64(32 + job.rounds * job.payloadBytes * 2)
                guard status.active, !status.operationInFlight, status.sealedRecords == expectedCount,
                      status.openedRecords == expectedCount, status.sealedPlaintextBytes == expectedBytes,
                      status.openedPlaintextBytes == expectedBytes else { throw ProbeError("Lab exact codec counters differ") }
                return (codec, copies, samples, status)
            }
            Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache(); try check(); try resources.finalCheck()
            guard releasedGroup == nil, Memory.activeMemory == resources.baselineNative,
                  Memory.cacheMemory == 0 else { throw ProbeError("Lab original native owner did not retire") }
            let report = LabRecordReport(job: job, scopeSHA256: job.scopeSHA256, codec: result.0, copies: result.1, transfers: result.2,
                sealedRecords: result.3.sealedRecords, openedRecords: result.3.openedRecords,
                sealedBytes: result.3.sealedPlaintextBytes, openedBytes: result.3.openedPlaintextBytes,
                baselineNativeBytes: resources.baselineNative, finalNativeBytes: Memory.activeMemory,
                maximumObservedNativeBytes: resources.maximumObservedNative,
                baselinePhysical: resources.baselinePhysical, finalPhysical: try .read(),
                minimumObservedFreeBytes: resources.minimumObservedFree, resourceObservations: resources.observations)
            let data = try canonicalJSONData(report)
            guard data.count <= 1_048_576 else { throw ProbeError("Lab report exceeds1MiB") }
            return data
        }
    }
}
