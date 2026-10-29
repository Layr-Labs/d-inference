import CryptoKit
import DarkbloomClusterSecurity
import Foundation
import MLX

struct LabCodecSample: Codable {
    let ordinal: Int, warmup: Bool, sealNanoseconds: UInt64, openNanoseconds: UInt64
    let plaintextBytes: Int, recordBytes: Int, verified: Bool
}
struct LabTransferSample: Codable {
    let mode: String, ordinal: Int, warmup: Bool
    let firstOperationNanoseconds: UInt64, secondOperationNanoseconds: UInt64, roundtripNanoseconds: UInt64
    let sent: LabFrameObservation, received: LabFrameObservation
    let plaintextSHA256: String, verified: Bool
}
struct LabCopySample: Codable {
    let ordinal: Int, warmup: Bool, exportNanoseconds: UInt64, importNanoseconds: UInt64
    let bytes: Int, verified: Bool
}
enum LabRecordMeasurements {
    static func recordBinding(_ job: LabRecordJob, _ domain: String) throws -> ClusterRecordBinding {
        let value = try job.binding(domain)
        return try .init(epoch: value.epoch, planSHA256: value.plan, membershipTranscriptSHA256: value.transcript)
    }
    static func context(_ job: LabRecordJob, _ domain: String) throws -> ClusterRecordContext {
        try .init(requestID: UUID(uuidString: job.runID)!, type: .residualPayload,
                  expectationSHA256: Data(SHA256.hash(data: Data((job.scopeSHA256 + "|" + domain).utf8))))
    }
    static func codec(_ job: LabRecordJob, key: SymmetricKey, plaintext: Data,
                      check: () throws -> Void) throws -> [LabCodecSample] {
        // Each host has a separate salt/domain, so these local fixture channels
        // never reuse a wire-channel key/nonce or each other's local counters.
        let binding = try recordBinding(job, "local-codec/rank\(job.rank)")
        let limits = try ClusterRecordLimits(maximumPlaintextBytes: plaintext.count,
            maximumRecordsPerDirection: UInt64(job.rounds),
            maximumCumulativePlaintextBytesPerDirection: UInt64(plaintext.count * job.rounds))
        let sender = try ClusterAuthenticatedRecordChannel(sessionKey: key, binding: binding, localRank: job.rank, limits: limits)
        let receiver = try ClusterAuthenticatedRecordChannel(sessionKey: key, binding: binding, localRank: 1 - job.rank, limits: limits)
        defer { sender.invalidate(); receiver.invalidate() }
        var samples = [LabCodecSample]()
        for ordinal in 0..<job.rounds {
            try check(); let context = try context(job, "local-codec/\(ordinal)")
            let sample = try autoreleasepool {
                let start = DispatchTime.now().uptimeNanoseconds
                let record = try sender.seal(plaintext, context: context)
                let sealed = DispatchTime.now().uptimeNanoseconds
                let result = try receiver.open(record, expecting: context)
                let opened = DispatchTime.now().uptimeNanoseconds
                guard result == plaintext, record.count == plaintext.count + 40 else { throw ProbeError("Lab local codec verification failed") }
                return LabCodecSample(ordinal: ordinal, warmup: ordinal < job.warmups,
                    sealNanoseconds: sealed - start, openNanoseconds: opened - sealed,
                    plaintextBytes: plaintext.count, recordBytes: record.count, verified: true)
            }
            samples.append(sample); try check()
        }
        guard sender.status.sealedRecords == UInt64(job.rounds), receiver.status.openedRecords == UInt64(job.rounds),
              sender.status.sealedPlaintextBytes == UInt64(job.rounds * plaintext.count),
              receiver.status.openedPlaintextBytes == UInt64(job.rounds * plaintext.count) else { throw ProbeError("Lab local codec counters differ") }
        return samples
    }

    static func copies(_ job: LabRecordJob, plaintext: Data, check: () throws -> Void) throws -> [LabCopySample] {
        let input = try CollectivePointToPoint.materializeCompletedBytes(plaintext, shape: [plaintext.count],
            dtype: .uint8, maximumBytes: plaintext.count, check: check)
        var samples = [LabCopySample]()
        for ordinal in 0..<job.rounds {
            try check()
            let value = try autoreleasepool {
                let start = DispatchTime.now().uptimeNanoseconds
                let copied = try CollectivePointToPoint.copyCompletedBytes(input, maximumBytes: plaintext.count, check: check)
                let exported = DispatchTime.now().uptimeNanoseconds
                let output = try CollectivePointToPoint.materializeCompletedBytes(copied, shape: [plaintext.count],
                    dtype: .uint8, maximumBytes: plaintext.count, check: check)
                let imported = DispatchTime.now().uptimeNanoseconds
                let verified = try CollectivePointToPoint.copyCompletedBytes(output, maximumBytes: plaintext.count, check: check)
                guard copied == plaintext, verified == plaintext else { throw ProbeError("Lab completed native copy changed bytes") }
                return LabCopySample(ordinal: ordinal, warmup: ordinal < job.warmups,
                    exportNanoseconds: exported - start, importNanoseconds: imported - exported,
                    bytes: plaintext.count, verified: true)
            }
            samples.append(value)
        }
        return samples
    }

    static func transfer(job: LabRecordJob, mode: String, ordinal: Int, plaintext: Data,
                         io: LabTimedRecordIO, records: ClusterAuthenticatedRecordTransport,
                         arrays: CollectiveAuthenticatedRecords, check: () throws -> Void) throws -> LabTransferSample {
        let context = try context(job, "\(mode)/\(ordinal)")
        let expectation = try ClusterRecordTransferExpectation(context: context, length: .exact(plaintext.count))
        let raw = mode == "raw_record_size" ? plaintext + Data(repeating: 0x37, count: 40) : plaintext
        var received = Data(), output: MLXArray?
        let input: MLXArray? = mode == "encrypted_array"
            ? try CollectivePointToPoint.materializeCompletedBytes(plaintext, shape: [plaintext.count], dtype: .uint8,
                maximumBytes: plaintext.count, check: check) : nil
        func send() throws {
            switch mode {
            case "raw_payload", "raw_record_size": try io.sendCompleted(job.rank == 0 ? raw : received, check: check)
            case "encrypted_record": try records.send(job.rank == 0 ? plaintext : received, expecting: expectation, check: check)
            case "encrypted_array":
                guard let tensor = job.rank == 0 ? input : output else { throw ProbeError("Lab array echo missing") }
                try arrays.sendArray(tensor, context: context, expectedShape: [plaintext.count], expectedDType: .uint8, check: check)
            default: throw ProbeError("Lab transfer mode differs")
            }
        }
        func receive() throws {
            switch mode {
            case "raw_payload", "raw_record_size": received = try io.receiveCompleted(byteCount: raw.count, check: check)
            case "encrypted_record": received = try records.receive(expecting: expectation, check: check)
            case "encrypted_array": output = try arrays.receiveArray(context: context, expectedShape: [plaintext.count], expectedDType: .uint8, check: check)
            default: throw ProbeError("Lab transfer mode differs")
            }
        }
        try check()
        let start = DispatchTime.now().uptimeNanoseconds
        if job.rank == 0 { try send() } else { try receive() }
        let middle = DispatchTime.now().uptimeNanoseconds
        if job.rank == 0 { try receive() } else { try send() }
        let end = DispatchTime.now().uptimeNanoseconds
        if let output {
            received = try CollectivePointToPoint.copyCompletedBytes(output, maximumBytes: plaintext.count, check: check)
        }
        let expected = mode.hasPrefix("raw_") ? raw : plaintext
        guard received == expected else { throw ProbeError("Lab exact roundtrip bytes differ") }
        let frames = try io.take()
        let frameBytes = mode == "raw_payload" ? plaintext.count : plaintext.count + 40
        guard frames.0.bytes == frameBytes, frames.1.bytes == frameBytes else { throw ProbeError("Lab frame byte accounting differs") }
        try check()
        return .init(mode: mode, ordinal: ordinal, warmup: ordinal < job.warmups,
            firstOperationNanoseconds: middle - start, secondOperationNanoseconds: end - middle,
            roundtripNanoseconds: end - start, sent: frames.0, received: frames.1,
            plaintextSHA256: sha256(expected), verified: true)
    }
}
