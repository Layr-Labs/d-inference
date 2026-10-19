import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

@Suite("Four-stream preflight and actual compact collective transfers", .serialized)
struct ResidualStreamTransportTests {
    private func request(prompt: Int, chunk: Int, streams: Int? = 4) throws -> QwenLayerStageGenerationRequest {
        let profile = try QwenLayerStageGenerationProfile(identifier: "residual-transport-fixture",
            vocabularySize: 64, hiddenSize: 4096, activationDType: "bfloat16",
            maximumPromptTokens: 4096, maximumChunkTokens: 4096, maximumOutputTokens: 2,
            maximumContextTokens: 8192, residualStreams: streams)
        return try .init(profile: profile, requestID: UUID(), promptTokenIDs: Array(repeating: 1, count: prompt),
            chunkSize: chunk, outputCount: 2, stopTokenIDs: [])
    }

    @Test func driverPreflightAdmits512AndRefuses513BeforeAnyCollectiveOrArray() throws {
        let exact = try qwenGenerationBoundaryGeometry(request: request(prompt: 512, chunk: 512), dtype: .bfloat16)
        #expect(exact.shape == [1, 512, 4, 4096])
        #expect(exact.byteCount == 16 * 1024 * 1024)
        #expect(throws: ProbeError.self) {
            try qwenGenerationBoundaryGeometry(request: request(prompt: 513, chunk: 513), dtype: .bfloat16)
        }
        // A short prompt never allocates the unused part of its chunk ceiling.
        let short = try qwenGenerationBoundaryGeometry(request: request(prompt: 512, chunk: 513), dtype: .bfloat16)
        #expect(short.byteCount == exact.byteCount)
        let legacy = try qwenGenerationBoundaryGeometry(request: request(prompt: 2048, chunk: 2048, streams: nil), dtype: .bfloat16)
        #expect(legacy.shape == [1, 2048, 4096] && legacy.byteCount == exact.byteCount)
        #expect(throws: ProbeError.self) {
            try qwenGenerationBoundaryGeometry(request: request(prompt: 2049, chunk: 2049, streams: nil), dtype: .bfloat16)
        }
        #expect(throws: ProbeError.self) {
            try qwenGenerationBoundaryGeometry(request: request(prompt: 1, chunk: 1), dtype: .float32)
        }
    }

    @Test func encrypted2048TokenBoundaryKeepsEveryRawRecordBounded() throws {
        let exact = try qwenGenerationBoundaryGeometry(request: request(prompt: 2048, chunk: 2048),
            dtype: .bfloat16, authenticatedChunking: true)
        #expect(exact.shape == [1, 2048, 4, 4096])
        #expect(exact.byteCount == 64 * 1024 * 1024)
        let parts = CollectiveAuthenticatedRecords.chunks(exact.byteCount,
            size: CollectiveAuthenticatedRecords.chunkBytes)
        #expect(parts.count == 8 && parts.first?.lowerBound == 0 && parts.last?.upperBound == exact.byteCount)
        #expect(parts.allSatisfy { $0.count == 8 * 1024 * 1024 })
        for pair in zip(parts, parts.dropFirst()) { #expect(pair.0.upperBound == pair.1.lowerBound) }
        #expect(throws: ProbeError.self) {
            _ = try qwenGenerationBoundaryGeometry(request: request(prompt: 2049, chunk: 2049),
                dtype: .bfloat16, authenticatedChunking: true)
        }
        #expect(throws: ProbeError.self) {
            _ = try CollectivePointToPointShape(shape: exact.shape, dtype: exact.dtype, maximumBytes: exact.byteCount)
        }
        #expect(throws: ProbeError.self) {
            _ = try qwenGenerationBoundaryGeometry(request: request(prompt: 2048, chunk: 2048), dtype: .bfloat16)
        }
        let short = try qwenGenerationBoundaryGeometry(request: request(prompt: 513, chunk: 2048),
            dtype: .bfloat16, authenticatedChunking: true)
        #expect(short.byteCount == 513 * 4 * 4096 * 2)
        #expect(CollectivePointToPointShape.hardByteLimit == 16 * 1024 * 1024)
    }

    private func agreement() throws -> QwenLayerStageGenerationAgreement {
        let source = try QwenLayerStageWireSourceIdentity(
            sourceConfigurationSHA256: String(repeating: "a", count: 64),
            artifactAggregateSHA256: String(repeating: "b", count: 64),
            storageCommitmentSHA256: String(repeating: "c", count: 64),
            planFingerprint: String(repeating: "d", count: 64),
            producerStageFingerprint: String(repeating: "e", count: 64))
        return try .init(request: request(prompt: 1, chunk: 1), membershipEpoch: UUID(), source: source,
            consumerStageFingerprint: String(repeating: "f", count: 64),
            rankBuildSHA256: [String(repeating: "1", count: 64), String(repeating: "2", count: 64)],
            numericalPolicySHA256: String(repeating: "3", count: 64), compactDecode: true)
    }

    private func expectation(_ agreement: QwenLayerStageGenerationAgreement) throws -> QwenLayerStageGenerationBoundaryExpectation {
        try .init(agreement: agreement, frame: agreement.request.frame(sequence: 1), tokenIDs: [2],
            previousTokenChainSHA256: String(repeating: "4", count: 64))
    }

    private func payload() -> Data {
        // Distinct BF16 bit patterns throughout every stream, with no arithmetic
        // conversion in the expected bytes. The native transport must keep all.
        let words = (0..<(4 * 4096)).map { UInt16(0x3f00 + $0 % 512).littleEndian }
        return words.withUnsafeBytes { Data($0) }
    }

    private struct Received {
        let shape: [Int]
        let dtype: String
        let bytes: Data
        let packetFingerprint: String
        let tokenFingerprint: String
        let hasOwnedCompactStorage: Bool
        let failed: Bool
    }

    @Test func compactBoundaryAndTokenRoundTripPreserveEveryFourStreamByte() throws {
        let agreement = try agreement(), expected = try expectation(agreement), bytes = payload()
        let pair = try ResidualStreamCollectiveFixture()
        let sender = try QwenLayerStageGenerationTransport(agreement: agreement, collective: pair.first)
        defer { sender.retire() }
        let array = try CollectivePointToPoint.materializeCompletedBytes(bytes, shape: expected.shape,
            dtype: .bfloat16, maximumBytes: expected.byteCount, check: {})
        let descriptor = agreement.descriptor
        let boundary = QwenLayerStageBoundary(requestFingerprint: expected.requestFingerprint,
            sourceConfigurationSHA256: descriptor.sourceConfigurationSHA256,
            artifactAggregateSHA256: descriptor.artifactAggregateSHA256,
            storageCommitmentSHA256: descriptor.storageCommitmentSHA256, planFingerprint: descriptor.planFingerprint,
            producerStageFingerprint: descriptor.stageFingerprints[0], frame: expected.frame,
            tokenIDsSHA256: expected.tokenIDsSHA256, payloadSHA256: sha256(bytes), array: array)
        let packet = try QwenLayerStageGenerationBoundaryPacket(expected: expected, payloadSHA256: boundary.payloadSHA256)
        var returnedToken: QwenLayerStageGenerationTokenPacket?
        let received = try pair.exchange(send: {
            try sender.sendCompactBoundary(boundary, packet: packet, check: {})
            returnedToken = try sender.receiveCompactToken(boundaryFingerprint: packet.fingerprint,
                previousChain: expected.previousTokenChainSHA256, ordinal: 1, committedTokens: 2, check: {})
        }, receive: { peer -> Received in
            let receiver = try QwenLayerStageGenerationTransport(agreement: agreement, collective: peer)
            defer { receiver.retire() }
            let (boundary, packet) = try receiver.receiveCompactBoundary(expected: expected, check: {})
            // Capture after validation and before replying; the reply is the
            // compact path's consumer acknowledgement, not a mocked callback.
            let shape = boundary.array.shape, dtype = String(describing: boundary.array.dtype)
            let actual = boundary.array.asData().data, owned = boundary.hasOwnedCompactStorage
            let token = try QwenLayerStageGenerationTokenPacket(agreement: agreement,
                boundaryFingerprint: packet.fingerprint, previousTokenChainSHA256: expected.previousTokenChainSHA256,
                ordinal: 1, committedTokens: 2, tokenID: 7)
            try receiver.sendCompactToken(token, check: {})
            return Received(shape: shape, dtype: dtype, bytes: actual,
                packetFingerprint: packet.fingerprint, tokenFingerprint: token.fingerprint,
                hasOwnedCompactStorage: owned, failed: receiver.isFailed)
        })
        let token = try #require(returnedToken)
        #expect(received.shape == [1, 1, 4, 4096] && received.dtype == "bfloat16")
        #expect(received.bytes == bytes && received.hasOwnedCompactStorage)
        #expect(received.packetFingerprint == packet.fingerprint)
        #expect(token.content.tokenID == 7 && token.fingerprint == received.tokenFingerprint)
        #expect(!sender.isFailed && !received.failed)
    }

    @Test(arguments: ["declaredHeaderLength", "shortPayload"])
    func malformedCompactBodyLengthPoisonsActualReceiver(change: String) throws {
        let agreement = try agreement(), expected = try expectation(agreement), bytes = payload()
        let packet = try QwenLayerStageGenerationBoundaryPacket(expected: expected, payloadSHA256: sha256(bytes))
        let header = packet.encoded()
        let declaredLength = UInt32(header.count + (change == "declaredHeaderLength" ? 1 : 0))
        var body = Data([UInt8(truncatingIfNeeded: declaredLength >> 24), UInt8(truncatingIfNeeded: declaredLength >> 16),
                         UInt8(truncatingIfNeeded: declaredLength >> 8), UInt8(truncatingIfNeeded: declaredLength)])
        body.append(header)
        body.append(change == "shortPayload" ? Data(bytes.dropLast()) : bytes)
        // A valid outer frame, including padding and transport length, carries
        // an invalid inner length. It must reach the actual compact receiver.
        let frameBytes = (QwenControlFrame.headerBytes + 4
            + QwenLayerStageGenerationTransport.compactHeaderLimit + expected.byteCount + 4095) / 4096 * 4096
        let frame = try QwenControlFrame.encode(body, frameBytes: frameBytes)
        let array = try CollectivePointToPoint.materializeCompletedBytes(frame, shape: [frameBytes],
            dtype: .uint8, maximumBytes: frameBytes, check: {})
        let pair = try ResidualStreamCollectiveFixture()
        let failure = try pair.exchange(send: {
            _ = try pair.first.sendCompleted(array, to: 1, maximumBytes: frameBytes,
                scope: .request(.residualPayload, requestID: agreement.request.requestID,
                    agreementFingerprint: agreement.fingerprint, "compact-boundary"), check: {})
        }, receive: { peer -> (String, Bool, Bool) in
            let receiver = try QwenLayerStageGenerationTransport(agreement: agreement, collective: peer)
            defer { receiver.retire() }
            var reason = "accepted malformed frame"
            do { _ = try receiver.receiveCompactBoundary(expected: expected, check: {}) }
            catch { reason = String(describing: error) }
            let failed = receiver.isFailed
            var refusedAgain = false
            if failed {
                do { _ = try receiver.receiveCompactBoundary(expected: expected, check: {}) }
                catch { refusedAgain = String(describing: error).contains("transport is failed") }
            }
            return (reason, failed, refusedAgain)
        })
        #expect(failure.0.contains("expected header and residual sizes"))
        #expect(failure.1 && failure.2)
    }
}
