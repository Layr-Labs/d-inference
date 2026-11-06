import CryptoKit
import Foundation

struct RecordBenchmarkSample: Encodable {
    let ordinal: Int
    let plaintextBytes: Int
    let sealedBytes: Int
    let sealNanoseconds: UInt64
    let openNanoseconds: UInt64
    let pairedNanoseconds: UInt64
    let betweenCallsNanoseconds: UInt64
}

struct RecordBenchmarkCase: Encodable {
    let name: String
    let sourceRank: Int
    let destinationRank: Int
    let plaintextBytes: Int
    let sealedBytes: Int
    let freshSessionKeyGenerated: Bool
    let warmupCount: Int
    let measuredCount: Int
    let verifiedPlaintextCount: Int
    let sequenceStartsAt: UInt64
    let sequenceEndsAt: UInt64
    let sealedRecords: UInt64
    let openedRecords: UInt64
    let sealedPlaintextBytes: UInt64
    let openedPlaintextBytes: UInt64
    let codecsInvalidatedAfterMeasurements: Bool
    let warmup: [RecordBenchmarkSample]
    let samples: [RecordBenchmarkSample]
}

enum RecordBenchmarkError: Error { case input, clock, content, counters }

private func nanoseconds(_ start: UInt64, _ end: UInt64) throws -> UInt64 {
    guard end >= start else { throw RecordBenchmarkError.clock }
    return end - start
}

/// Both operations execute sequentially on this CPU. There is no network,
/// transport, MLX allocation, GPU readback or native model in this measurement.
private func measure(sender: ClusterAuthenticatedRecordChannel,
                     receiver: ClusterAuthenticatedRecordChannel,
                     payload: Data, context: ClusterRecordContext,
                     sequence: Int) throws -> RecordBenchmarkSample {
    let sealStart = DispatchTime.now().uptimeNanoseconds
    let sealed = try sender.seal(payload, context: context)
    let sealEnd = DispatchTime.now().uptimeNanoseconds
    let openStart = DispatchTime.now().uptimeNanoseconds
    let opened = try receiver.open(sealed, expecting: context)
    let openEnd = DispatchTime.now().uptimeNanoseconds

    // Content verification is outside the timed methods. All allocations,
    // framing, counters and authentication inside the real codec stay timed.
    guard opened == payload, sealed.count == payload.count + 40 else { throw RecordBenchmarkError.content }
    return .init(ordinal: sequence, plaintextBytes: payload.count, sealedBytes: sealed.count,
        sealNanoseconds: try nanoseconds(sealStart, sealEnd),
        openNanoseconds: try nanoseconds(openStart, openEnd),
        pairedNanoseconds: try nanoseconds(sealStart, openEnd),
        betweenCallsNanoseconds: try nanoseconds(sealEnd, openStart))
}

func runRecordBenchmarkCase(name: String, bytes: Int, sourceRank: Int,
                            warmups: Int, samples: Int) throws -> RecordBenchmarkCase {
    guard [4_194_304, 5_242_880, 8_192, 10_240].contains(bytes),
          (0...1).contains(sourceRank), warmups == 3, samples == 20 else {
        throw RecordBenchmarkError.input
    }
    let count = warmups + samples
    let total = UInt64(bytes).multipliedReportingOverflow(by: UInt64(count))
    guard !total.overflow else { throw RecordBenchmarkError.input }
    let limits = try ClusterRecordLimits(maximumPlaintextBytes: bytes,
        maximumRecordsPerDirection: UInt64(count), maximumCumulativePlaintextBytesPerDirection: total.partialValue)
    // Actual fresh random secret and epoch for each size/direction case. There
    // are no resets or retries with the same sender key/sequence context.
    let key = SymmetricKey(size: .bits256)
    let binding = try ClusterRecordBinding(epoch: UUID(),
        planSHA256: Data(SHA256.hash(data: Data("cpu-fixture-plan-not-a-model".utf8))),
        membershipTranscriptSHA256: Data(SHA256.hash(data: Data("cpu-fixture-not-membership-authority".utf8))))
    let sender = try ClusterAuthenticatedRecordChannel(sessionKey: key, binding: binding,
        localRank: sourceRank, limits: limits)
    let receiver = try ClusterAuthenticatedRecordChannel(sessionKey: key, binding: binding,
        localRank: 1 - sourceRank, limits: limits)
    defer { sender.invalidate(); receiver.invalidate() }
    var payload = Data(count: bytes)
    payload.withUnsafeMutableBytes { raw in
        let values = raw.bindMemory(to: UInt8.self)
        for index in 0..<bytes { values[index] = UInt8((index * 29 + sourceRank * 17 + 43) & 255) }
    }
    let metadata = Data("cpu-fixture/bytes=\(bytes)/source=\(sourceRank)/residual".utf8)
    let expectation = Data(SHA256.hash(data: metadata))
    var warmup = [RecordBenchmarkSample](), measured = [RecordBenchmarkSample]()
    for ordinal in 0..<count {
        let context = try ClusterRecordContext(requestID: UUID(), type: .residualPayload,
            expectationSHA256: expectation)
        let sample = try autoreleasepool {
            try measure(sender: sender, receiver: receiver, payload: payload, context: context, sequence: ordinal)
        }
        if ordinal < warmups { warmup.append(sample) } else { measured.append(sample) }
    }
    let sendStatus = sender.status, receiveStatus = receiver.status
    guard sendStatus.sealedRecords == UInt64(count), sendStatus.openedRecords == 0,
          receiveStatus.openedRecords == UInt64(count), receiveStatus.sealedRecords == 0,
          sendStatus.sealedPlaintextBytes == total.partialValue,
          receiveStatus.openedPlaintextBytes == total.partialValue,
          !sendStatus.operationInFlight, !receiveStatus.operationInFlight else {
        throw RecordBenchmarkError.counters
    }
    sender.invalidate(); receiver.invalidate()
    return .init(name: name, sourceRank: sourceRank, destinationRank: 1 - sourceRank,
        plaintextBytes: bytes, sealedBytes: bytes + 40, freshSessionKeyGenerated: true,
        warmupCount: warmups, measuredCount: samples, verifiedPlaintextCount: count,
        sequenceStartsAt: 0, sequenceEndsAt: UInt64(count - 1),
        sealedRecords: sendStatus.sealedRecords, openedRecords: receiveStatus.openedRecords,
        sealedPlaintextBytes: sendStatus.sealedPlaintextBytes, openedPlaintextBytes: receiveStatus.openedPlaintextBytes,
        codecsInvalidatedAfterMeasurements: !sender.status.active && !receiver.status.active,
        warmup: warmup, samples: measured)
}
