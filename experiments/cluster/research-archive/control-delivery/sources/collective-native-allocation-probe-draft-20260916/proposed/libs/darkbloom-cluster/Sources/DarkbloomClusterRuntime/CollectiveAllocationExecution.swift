#if COLLECTIVE_RECORD_ALLOCATION_CHECK
import CryptoKit
import DarkbloomClusterSecurity
import Foundation
import MLX

enum CollectiveAllocationCancellation: Error { case injected }
struct CollectiveAllocationExecution {
    let sentRecords: UInt64
    let openedRecords: UInt64
    let publishedArrays: Int
    let refusedRecords: Int
    let frameLengths: [Int]
    let expectedPlaintextBytes: [Int]
    let actualInputByteCounts: [Int]
    let attemptedShapes: [[Int]]
    let attemptedDTypes: [String]
    let verifiedPlaintextDigests: [String]
    let senderActiveBeforeCleanup: Bool
    let receiverActiveBeforeCleanup: Bool
    let weakArrays: [CollectiveAllocationWeakArray]

    static func run(_ test: CollectiveAllocationCase, check: () throws -> Void) throws -> Self {
        let mailbox = CollectiveAllocationMailbox(.none)
        let key = SymmetricKey(data: Data(repeating: 0x63, count: 32)) // public fixture bytes only
        let binding = try ClusterRecordBinding(epoch: UUID(), planSHA256: Data(repeating: 0x21, count: 32),
            membershipTranscriptSHA256: Data(repeating: 0x42, count: 32))
        let limits = try ClusterRecordLimits(maximumPlaintextBytes: CollectiveAllocationCase.maximumPlaintextBytes)
        let sender = try CollectiveAuthenticatedRecords(io: .init(endpoint: CollectiveAllocationEndpoint(rank: 0, mailbox: mailbox),
            maximumFrameBytes: CollectiveAllocationCase.maximumFrameBytes), sessionKey: key, binding: binding, limits: limits)
        let receiver = try CollectiveAuthenticatedRecords(io: .init(endpoint: CollectiveAllocationEndpoint(rank: 1, mailbox: mailbox),
            maximumFrameBytes: CollectiveAllocationCase.maximumFrameBytes), sessionKey: key, binding: binding, limits: limits)
        defer { sender.invalidate(); receiver.invalidate(); mailbox.frame = nil }
        let request = try CollectiveRequestScope(requestID: UUID(), epoch: binding.epoch,
            planSHA256: String(repeating: "21", count: 32), agreementSHA256: String(repeating: "31", count: 32))
        var published = 0, refused = 0, sizes: [Int] = [], digests: [String] = []
        var actualSizes: [Int] = [], attemptedShapes: [[Int]] = [], attemptedTypes: [String] = []
        var currentFailure = CollectiveAllocationCase.Failure.none
        var sentBefore: UInt64 = 0, openedBefore: UInt64 = 0
        func injectedCheck() throws {
            try check()
            switch currentFailure {
            case .beforeExport: throw CollectiveAllocationCancellation.injected
            case .afterSeal where sender.status.codec.sealedRecords > sentBefore: throw CollectiveAllocationCancellation.injected
            case .afterReceive where mailbox.nativeReceiveCompleted: throw CollectiveAllocationCancellation.injected
            case .afterOpen where receiver.status.codec.openedRecords > openedBefore: throw CollectiveAllocationCancellation.injected
            default: break
            }
        }
        let operations = test.priming.map { ($0, CollectiveAllocationCase.Failure.none) }
            + (0..<test.rounds).flatMap { _ in test.geometries.map { ($0, test.failure) } }
        for (geometry, failure) in operations {
            currentFailure = failure; mailbox.failure = failure; mailbox.nativeReceiveCompleted = false
            sentBefore = sender.status.codec.sealedRecords; openedBefore = receiver.status.codec.openedRecords
            let publishedBefore = published
            try autoreleasepool {
                try check()
                let invalid = failure == .oversize || failure == .shape
                let shape = invalid ? [1] : geometry.shape
                let dtype = invalid ? DType.uint32 : geometry.dtype
                let bytes = invalid ? 4 : geometry.bytes
                let input = try CollectivePointToPoint.materializeCompletedBytes(Data(repeating: 0x5a, count: bytes),
                    shape: shape, dtype: dtype, maximumBytes: bytes, check: check)
                try mailbox.track(input)
                let context = try request.operation(.residualPayload,
                    metadata: Data((test.id + "|" + geometry.id).utf8)).part(.array).context
                let expectedShape = failure == .oversize ? [CollectiveAllocationCase.maximumPlaintextBytes + 1]
                    : failure == .shape ? [2] : geometry.shape
                let expectedDType = failure == .oversize ? DType.uint8 : dtype
                sizes.append(expectedShape.reduce(1, *) * expectedDType.size)
                actualSizes.append(bytes); attemptedShapes.append(expectedShape); attemptedTypes.append(String(describing: expectedDType))
                do {
                    try sender.sendArray(input, context: context, expectedShape: expectedShape,
                        expectedDType: expectedDType, check: injectedCheck)
                    let output = try receiver.receiveArray(context: context, expectedShape: expectedShape,
                        expectedDType: expectedDType, check: injectedCheck)
                    published += 1; try mailbox.track(output)
                    guard failure == .none else { throw ProbeError("Failure case published native plaintext") }
                    let actual = try CollectivePointToPoint.copyCompletedBytes(output, maximumBytes: bytes, check: check)
                    guard actual.count == bytes, actual.allSatisfy({ $0 == 0x5a }) else {
                        throw ProbeError("Allocation probe changed authenticated native bytes")
                    }
                    digests.append(SHA256.hash(data: actual).map { String(format: "%02x", $0) }.joined())
                } catch {
                    try check() // Native/resource/deadline errors cannot count as expected refusal.
                    let expected: Bool
                    switch failure {
                    case .ciphertext, .tag: expected = (error as? ClusterRecordError) == .authenticationFailed
                    case .beforeExport, .afterSeal, .afterReceive, .afterOpen: expected = error is CollectiveAllocationCancellation
                    case .oversize: expected = (error as? ProbeError)?.description == "Point-to-point transfer exceeds the admitted byte limit"
                    case .shape: expected = (error as? ProbeError)?.description == "Point-to-point transfer changed native array metadata"
                    case .none: expected = false
                    }
                    guard expected, published == publishedBefore else { throw error }
                    refused += 1
                }
            }
        }
        let sent = sender.status, opened = receiver.status
        let count = UInt64(operations.count)
        let primed = UInt64(test.priming.count)
        if test.failure == .none {
            guard sent.active, opened.active, sent.codec.sealedRecords == count,
                  opened.codec.openedRecords == count, published == Int(count), refused == 0,
                  mailbox.frame == nil, mailbox.lengths == sizes.map({ $0 + 40 }) else {
                throw ProbeError("Allocation success counters or exact frames differ")
            }
        } else {
            let beforeSend = [.beforeExport, .oversize, .shape].contains(test.failure)
            let beforeIO = beforeSend || test.failure == .afterSeal
            let afterOpen = test.failure == .afterOpen
            guard refused == 1, published == Int(primed),
                  sent.codec.sealedRecords == primed + (beforeSend ? 0 : 1),
                  opened.codec.openedRecords == primed + (afterOpen ? 1 : 0),
                  mailbox.lengths.count == Int(primed) + (beforeIO ? 0 : 1),
                  (beforeIO ? !sent.active : !opened.active) else {
                throw ProbeError("Allocation failure did not poison the expected owner before publication")
            }
        }
        return .init(sentRecords: sent.codec.sealedRecords, openedRecords: opened.codec.openedRecords,
            publishedArrays: published, refusedRecords: refused, frameLengths: mailbox.lengths,
            expectedPlaintextBytes: sizes, actualInputByteCounts: actualSizes, attemptedShapes: attemptedShapes,
            attemptedDTypes: attemptedTypes, verifiedPlaintextDigests: digests,
            senderActiveBeforeCleanup: sent.active, receiverActiveBeforeCleanup: opened.active, weakArrays: mailbox.weakArrays)
    }
}
#endif
