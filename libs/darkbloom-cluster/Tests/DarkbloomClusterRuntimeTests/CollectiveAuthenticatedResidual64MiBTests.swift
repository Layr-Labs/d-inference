import CryptoKit
import DarkbloomClusterSecurity
import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

/// Native execution belongs to the parent's exclusive lane. The array-level
/// sender, receiver and echo run sequentially. Each sealed frame is completed
/// over the existing socket pair and joined before the next frame is started.
@Suite("Authenticated GLM 2048-token residual transport", .serialized)
struct CollectiveAuthenticatedResidual64MiBTests {
    private static let shape = [1, 2048, 4, 4096]
    private static let residualBytes = 67_108_864
    private static let recordBytes = 8_388_608
    private static let frameBytes = recordBytes + 40

    private enum Failure: Error { case deadline, queueBound, missingFrame, unexpectedSuccess }

    /// Only ciphertext is queued. All accesses occur on the calling test thread;
    /// exchange joins its one network worker before returning. The network
    /// worker checks an immutable deadline, never an escaped caller closure.
    private final class SocketFrames {
        let pair: ResidualStreamCollectiveFixture
        let raw: [CollectiveRecordByteIO]
        private var pending: [[Data]] = [[], []]
        private(set) var transferredSizes: [[Int]] = [[], []]
        private(set) var receiveCalls = [0, 0]
        private let deadline = DispatchTime.now().uptimeNanoseconds + 120_000_000_000

        init() throws {
            let pair = try ResidualStreamCollectiveFixture(timeoutSeconds: 120, progressTimeoutSeconds: 30)
            self.pair = pair
            raw = try [pair.first, pair.last].map {
                try CollectiveRecordByteIO(collective: $0,
                    maximumFrameBytes: CollectiveAuthenticatedResidual64MiBTests.frameBytes)
            }
        }

        func send(_ frame: Data, from rank: Int, check: () throws -> Void) throws {
            // Eight actual encrypted records, never an unbounded mailbox.
            guard pending[1 - rank].count < 8,
                  !frame.isEmpty, frame.count <= CollectiveAuthenticatedResidual64MiBTests.frameBytes else {
                throw Failure.queueBound
            }
            let first = raw[0], last = raw[1]
            let deadline = self.deadline
            let nativeCheck: () throws -> Void = {
                guard DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.deadline }
            }
            try check()
            let delivered: Data = try {
                if rank == 0 {
                    return try pair.exchange(send: {
                        try first.sendCompleted(frame, check: check)
                    }, receive: { _ in
                        try last.receiveCompleted(byteCount: frame.count, check: nativeCheck)
                    })
                }
                var received: Data?
                try pair.exchange(send: {
                    received = try first.receiveCompleted(byteCount: frame.count, check: check)
                }, receive: { _ in
                    try last.sendCompleted(frame, check: nativeCheck)
                })
                guard let received else { throw Failure.missingFrame }
                return received
            }()
            try check()
            transferredSizes[rank].append(delivered.count)
            pending[1 - rank].append(delivered)
        }

        func receive(for rank: Int, byteCount: Int, check: () throws -> Void) throws -> Data {
            try check()
            receiveCalls[rank] += 1
            guard !pending[rank].isEmpty else { throw Failure.missingFrame }
            let frame = pending[rank].removeFirst()
            // A truncated wire frame is not a successful partial ByteIO read.
            guard frame.count == byteCount else { throw ClusterRecordTransferError.unexpectedByteCount }
            return frame
        }

        var empty: Bool { pending.allSatisfy(\.isEmpty) }
    }

    /// Intercepts the byte boundary after the real codec seals a record. It
    /// neither creates record scopes nor substitutes plaintext for ciphertext.
    private final class RecordEndpoint: ClusterRecordByteIO {
        let localRank: Int
        let worldSize = 2
        let maximumFrameBytes = CollectiveAuthenticatedResidual64MiBTests.frameBytes
        let wire: SocketFrames
        let fault: String?
        private(set) var faultApplied = false

        init(rank: Int, wire: SocketFrames, fault: String? = nil) {
            localRank = rank; self.wire = wire; self.fault = fault
        }

        func sendCompleted(_ bytes: Data, check: () throws -> Void) throws {
            try check()
            var frame = bytes
            if let fault, !faultApplied, wire.transferredSizes[localRank].count == 7 {
                guard frame.count == maximumFrameBytes else { throw Failure.queueBound }
                if fault == "ciphertext" {
                    // The first ciphertext byte, after the public record header.
                    frame[frame.startIndex + ClusterAuthenticatedRecordChannel.framingPrefixBytes] ^= 1
                } else if fault == "truncated" {
                    frame.removeLast() // Drop one authenticated-tag byte on the link.
                } else {
                    throw Failure.queueBound
                }
                faultApplied = true
            }
            try wire.send(frame, from: localRank, check: check)
        }

        func receiveCompleted(byteCount: Int, check: () throws -> Void) throws -> Data {
            try wire.receive(for: localRank, byteCount: byteCount, check: check)
        }
    }

    private final class Pair {
        let wire: SocketFrames
        let endpoints: [RecordEndpoint]
        let transports: [ClusterAuthenticatedRecordTransport]
        let arrays: [CollectiveAuthenticatedRecords]
        let receipts: [ClusterDataPlaneReceipt]
        private let deadline = DispatchTime.now().uptimeNanoseconds + 120_000_000_000

        init(fault: String? = nil) throws {
            let wire = try SocketFrames()
            self.wire = wire
            let endpoints = [RecordEndpoint(rank: 0, wire: wire, fault: fault),
                             RecordEndpoint(rank: 1, wire: wire)]
            self.endpoints = endpoints
            // Same fresh pinned-member credentials as GLM5NextResidentRuntimeTests,
            // without constructing its model artifact or loading either stage.
            let identities = [P256.Signing.PrivateKey(), P256.Signing.PrivateKey()]
            let epoch = UUID()
            let credentials = try (0...1).map { rank in
                try ClusterDataPlaneCredential.issue(identity: identities[rank], epoch: epoch, rank: rank,
                    peerPin: .init(identityPublicKey: identities[1 - rank].publicKey.x963Representation))
            }
            let scope = Data(SHA256.hash(data: Data("glm-2048-residual-transport-test".utf8)))
            let first = try ClusterDataPlaneKeyExchange(credential: credentials[0], scopeSHA256: scope)
            let last = try ClusterDataPlaneKeyExchange(credential: credentials[1], scopeSHA256: scope)
            // Actual signed-hello validation and key confirmation, as in DataPlaneChecks.
            // Only this setup exchanges hellos in memory; residual records use the sockets.
            let firstTag = try first.accept(peerHello: last.hello)
            let lastTag = try last.accept(peerHello: first.hello)
            try first.confirm(peerTag: lastTag)
            try last.confirm(peerTag: firstTag)
            let limits = try ClusterRecordLimits(maximumPlaintextBytes: CollectiveAuthenticatedRecords.chunkBytes)
            let a = try first.makeTransport(io: endpoints[0], limits: limits, rekey: .dataPlane)
            let b = try last.makeTransport(io: endpoints[1], limits: limits, rekey: .dataPlane)
            transports = [a.0, b.0]; receipts = [a.1, b.1]
            // The initializer checks rank/frame identity against the actual raw endpoint;
            // the record transport intercepts only bytes, via its existing ByteIO seam.
            arrays = try [CollectiveAuthenticatedRecords(transport: a.0, io: wire.raw[0]),
                          CollectiveAuthenticatedRecords(transport: b.0, io: wire.raw[1])]
        }

        func check() throws {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.deadline }
        }

        deinit { arrays.forEach { $0.invalidate() } }
    }

    private func scope() -> CollectiveRecordScope {
        .request(.residualPayload, requestID: UUID(),
            agreementFingerprint: String(repeating: "a", count: 64), "glm-2048-residual")
    }

    private func payload() -> Data {
        // Finite BF16 words vary by channel and stream. Each token has a distinct
        // marker, so swapping, repeating or zero-filling an 8 MiB chunk changes bytes.
        let words = (0..<(4 * 4096)).map { UInt16(0x3e00 + $0 % 1024).littleEndian }
        let token = words.withUnsafeBytes { Data($0) }
        var data = Data(capacity: Self.residualBytes)
        for index in 0..<2048 {
            let start = data.count
            data.append(token)
            data[start] = UInt8(truncatingIfNeeded: index)
            data[start + 1] = 0x3f
            data[start + 2] = UInt8(index >> 8)
            data[start + 3] = 0x40
        }
        return data
    }

    private func assertPayload(_ array: MLXArray, equals expected: Data) throws {
        #expect(array.shape == Self.shape)
        #expect(array.dtype == .bfloat16)
        let actual = try MLX.withError { error in
            let data = array.asData(access: .copy).data
            try error.check()
            return data
        }
        #expect(actual.count == Self.residualBytes)
        // Keep Data/MLXArray values out of failure rendering (64 MiB each).
        let everyByteMatches = actual == expected
        #expect(everyByteMatches, "The entire 64 MiB BF16 residual must survive encryption and native reconstruction")
        let bufferInfo = try array.evaluatedBufferInfo()
        let storage = try #require(bufferInfo)
        #expect(storage.isUnique && storage.isRowContiguous && storage.dataOffset == 0)
        #expect(storage.dataElements == 33_554_432)
    }

    private func failure<T>(of operation: () throws -> T) throws -> Error {
        do { _ = try operation() }
        catch { return error }
        throw Failure.unexpectedSuccess
    }

    @Test func fullResidualRoundTripUsesEightEncryptedRecordsPerDirection() throws {
        let bytes = payload()
        #expect(bytes.count == Self.residualBytes)
        let input = MLXArray(bytes, Self.shape, dtype: .bfloat16)
        let pair = try Pair(), scope = scope()
        let peersVerified = pair.receipts.allSatisfy(\.peerVerified)
        #expect(peersVerified)
        #expect(pair.receipts[0].transcriptSHA256 == pair.receipts[1].transcriptSHA256)
        #expect(pair.receipts[0].edgeID == pair.receipts[1].edgeID)
        #expect(CollectiveAuthenticatedRecords.chunkBytes == Self.recordBytes)
        #expect(CollectivePointToPointShape.hardByteLimit == 16_777_216)

        // No overlap between whole-array send, authenticated reconstruction and echo.
        try pair.arrays[0].sendArray(input, scope: scope, maximumBytes: Self.residualBytes, check: pair.check)
        let received = try pair.arrays[1].receiveArray(shape: Self.shape, dtype: .bfloat16,
            scope: scope, maximumBytes: Self.residualBytes, check: pair.check)
        try assertPayload(received, equals: bytes)
        try pair.arrays[1].sendArray(received, scope: scope, maximumBytes: Self.residualBytes, check: pair.check)
        let echoed = try pair.arrays[0].receiveArray(shape: Self.shape, dtype: .bfloat16,
            scope: scope, maximumBytes: Self.residualBytes, check: pair.check)
        try assertPayload(echoed, equals: bytes)

        for rank in 0...1 {
            let status = pair.arrays[rank].status
            #expect(status.active && status.codec.active && !status.operationInFlight)
            #expect(status.codec.sealedRecords == 8 && status.codec.openedRecords == 8)
            #expect(status.codec.sealedPlaintextBytes == UInt64(Self.residualBytes))
            #expect(status.codec.openedPlaintextBytes == UInt64(Self.residualBytes))
            #expect(pair.wire.transferredSizes[rank] == Array(repeating: Self.frameBytes, count: 8))
            #expect(pair.wire.receiveCalls[rank] == 8)
        }
        #expect(pair.wire.empty)
        // The raw API must reject the same array at admission, not time out after IO.
        let error = try failure {
            try pair.wire.pair.first.rawSendCompleted(input, to: 1,
                maximumBytes: Self.residualBytes, check: pair.check)
        }
        #expect(error is ProbeError)
        #expect(String(describing: error).contains("unsupported shape, dtype or byte limit"))
    }

    @Test(arguments: ["ciphertext", "truncated"])
    func damagedEighthRecordNeverPublishesAPartialResidual(fault: String) throws {
        let bytes = payload()
        let input = MLXArray(bytes, Self.shape, dtype: .bfloat16)
        let pair = try Pair(fault: fault), scope = scope()
        try pair.arrays[0].sendArray(input, scope: scope, maximumBytes: Self.residualBytes, check: pair.check)
        #expect(pair.endpoints[0].faultApplied)
        #expect(pair.arrays[0].status.codec.sealedRecords == 8)
        #expect(pair.arrays[0].status.codec.sealedPlaintextBytes == UInt64(Self.residualBytes))
        #expect(pair.wire.transferredSizes[0].count == 8)
        #expect(pair.wire.transferredSizes[0].last == Self.frameBytes - (fault == "truncated" ? 1 : 0))

        let error = try failure {
            try pair.arrays[1].receiveArray(shape: Self.shape, dtype: .bfloat16,
                scope: scope, maximumBytes: Self.residualBytes, check: pair.check)
        }
        if fault == "ciphertext" {
            #expect(error as? ClusterRecordError == .authenticationFailed)
        } else {
            #expect(error as? ClusterRecordTransferError == .unexpectedByteCount)
        }
        let status = pair.arrays[1].status
        #expect(!status.active && !status.codec.active && !status.operationInFlight)
        #expect(status.codec.openedRecords == 7)
        #expect(status.codec.openedPlaintextBytes == UInt64(7 * Self.recordBytes))
        #expect(pair.wire.receiveCalls[1] == 8 && pair.wire.empty)
        let retry = try failure {
            try pair.arrays[1].receiveArray(shape: [1], dtype: .uint8,
                scope: scope, maximumBytes: 1, check: pair.check)
        }
        #expect(retry as? ClusterRecordTransferError == .inactive)
        #expect(pair.wire.receiveCalls[1] == 8) // No raw retry after poisoning.
    }

    @Test(arguments: ["2049-tokens", "short-admission", "raised-ceiling"])
    func receiverBoundsFailBeforeReadingCiphertext(caseName: String) throws {
        let pair = try Pair()
        let shape = caseName == "2049-tokens" ? [1, 2049, 4, 4096] : Self.shape
        let limit = Self.residualBytes + (caseName == "short-admission" ? -1 : caseName == "raised-ceiling" ? 1 : 0)
        let error = try failure {
            try pair.arrays[1].receiveArray(shape: shape, dtype: .bfloat16,
                scope: scope(), maximumBytes: limit, check: pair.check)
        }
        #expect(error is ProbeError)
        #expect(pair.wire.receiveCalls[1] == 0 && pair.wire.empty)
        #expect(pair.arrays[1].status.codec.openedRecords == 0)
        #expect(!pair.arrays[1].status.active)
    }

    @Test(arguments: [1, 67_108_865])
    func senderBoundsFailBeforeSealingOrNativeTransfer(limit: Int) throws {
        let pair = try Pair()
        let input = MLXArray(Data([0x12, 0x34]), [2], type: UInt8.self)
        let error = try failure {
            try pair.arrays[0].sendArray(input, scope: scope(), maximumBytes: limit, check: pair.check)
        }
        #expect(error is ProbeError)
        #expect(pair.arrays[0].status.codec.sealedRecords == 0)
        #expect(!pair.arrays[0].status.active)
        #expect(pair.wire.transferredSizes[0].isEmpty && pair.wire.empty)
    }

    @Test func oversizedSingleRecordCannotUseTheLargerLogicalArrayAllowance() throws {
        let pair = try Pair()
        let tooLarge = Self.recordBytes + 1
        let expected = try scope().expectation(shape: [tooLarge], dtype: .uint8,
            chunk: 0, of: 1, length: tooLarge)
        let error = try failure {
            try pair.transports[0].send(Data(count: tooLarge), expecting: expected, check: pair.check)
        }
        #expect(error as? ClusterRecordTransferError == .invalidConfiguration)
        #expect(pair.transports[0].status.codec.sealedRecords == 0)
        #expect(!pair.transports[0].status.active)
        #expect(pair.wire.transferredSizes[0].isEmpty && pair.wire.empty)
        // Native ciphertext frame admission remains capped separately at 16 MiB.
        let rawLimitError = try failure {
            try CollectiveRecordByteIO(collective: pair.wire.pair.first, maximumFrameBytes: 16_777_217)
        }
        #expect(rawLimitError is ProbeError)
    }

    @Test(arguments: [0, 601, Int.max])
    func fixtureTimeoutOverridesRemainBounded(seconds: Int) throws {
        #expect(throws: ProbeError.self) {
            _ = try ResidualStreamCollectiveFixture(timeoutSeconds: seconds)
        }
        #expect(throws: ProbeError.self) {
            _ = try ResidualStreamCollectiveFixture(progressTimeoutSeconds: seconds)
        }
    }
}
