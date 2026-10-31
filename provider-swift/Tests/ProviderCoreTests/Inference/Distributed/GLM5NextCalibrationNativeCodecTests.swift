import CryptoKit
import Foundation
import Testing
import DarkbloomClusterSecurity

/// UNRUN private draft. No model/native initialization; public codec metadata only.
@Suite struct GLM5NextCalibrationNativeCodecTests {
    func common(artifact: UInt8 = 3) throws -> ClusterNativeAuthorizationCommon {
        try .init(finiteCalibrationRequestID: UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!,
            expiresUnixSeconds: 2000, epoch: UUID(uuidString: "01020304-0506-0708-090a-0b0c0d0e0f10")!,
            membershipGeneration: 7, membershipTranscriptSHA256: Data(repeating: 1, count: 32),
            planSHA256: Data(repeating: 2, count: 32), artifactSHA256: Data(repeating: artifact, count: 32),
            profileSHA256: Data(repeating: 4, count: 32), rank0AuthorizationSHA256: Data(repeating: 5, count: 32),
            rank1AuthorizationSHA256: Data(repeating: 6, count: 32), maximumTransportFrameBytes: 4136,
            limits: ClusterRecordLimits(maximumPlaintextBytes: 4096, maximumRecordsPerDirection: 64,
                maximumCumulativePlaintextBytesPerDirection: 262144))
    }
    func start(_ rank: Int, common: ClusterNativeAuthorizationCommon? = nil) throws -> ClusterNativeAuthorizationStart {
        try .init(common: common ?? self.common(), rank: rank,
            ownerIncarnation: UUID(), leaseID: UUID(), launchID: UUID())
    }
    func hello(_ start: ClusterNativeAuthorizationStart) throws -> ClusterNativeKeyHello {
        // Public canonical fixture points, not a private-key/native context.
        try .init(start: start, publicKey: Data([UInt8(start.rank + 9)]) + Data(repeating: 0, count: 31))
    }
    @Test func finiteArtifactAndExactCommonSurviveEveryCodecBoundary() throws {
        let common = try common(), s0 = try start(0, common: common), s1 = try start(1, common: common)
        let h0 = try hello(s0), h1 = try hello(s1), binding = try ClusterNativeKeyBinding(hellos: [h0, h1])
        #expect(s0.canonicalBytes[4] == 2 && h0.canonicalBytes[4] == 2 && binding.canonicalBytes[4] == 2)
        let decoded = try ClusterNativeKeyBinding(encoded: binding.canonicalBytes)
        #expect(decoded.canonicalBytes == binding.canonicalBytes)
        #expect(decoded.transcriptSHA256 == binding.transcriptSHA256)
        for (rank, h) in decoded.hellos.enumerated() {
            #expect(h.start.rank == rank)
            #expect(h.start.common.canonicalBytes == common.canonicalBytes)
            #expect(h.start.common.artifactSHA256 == Data(repeating: 3, count: 32))
            guard case .finiteCalibrationV1(let f) = h.start.common.permission else { Issue.record("purpose lost"); return }
            #expect(f.expiresUnixSeconds == 2000)
            #expect(f.rank0AuthorizationSHA256 == Data(repeating: 5, count: 32))
            #expect(f.rank1AuthorizationSHA256 == Data(repeating: 6, count: 32))
        }
        #expect(throws: (any Error).self) {
            try ClusterNativeKeyBinding(hellos: [h0, hello(start(1, common: self.common(artifact: 8)))])
        }
    }
    @Test func versionsExactCountsSuiteAndPublicKeyValidationRemainClosed() throws {
        let start = try start(0), hello = try hello(start)
        let binding = try ClusterNativeKeyBinding(hellos: [hello, self.hello(self.start(1, common: start.common))])
        for version in [UInt8(0), 1, 3, 255] {
            var bytes = start.canonicalBytes; bytes[4] = version
            #expect(throws: (any Error).self) { try ClusterNativeAuthorizationStart(encoded: bytes) }
            bytes = hello.canonicalBytes; bytes[4] = version
            #expect(throws: (any Error).self) { try ClusterNativeKeyHello(encoded: bytes) }
            bytes = binding.canonicalBytes; bytes[4] = version
            #expect(throws: (any Error).self) { try ClusterNativeKeyBinding(encoded: bytes) }
        }
        for bytes in [start.canonicalBytes + Data([0]), Data(start.canonicalBytes.dropLast())] {
            #expect(throws: (any Error).self) { try ClusterNativeAuthorizationStart(encoded: bytes) }
        }
        #expect(throws: (any Error).self) { try ClusterNativeKeyHello(encoded: hello.canonicalBytes + Data([0])) }
        #expect(throws: (any Error).self) { try ClusterNativeKeyBinding(encoded: binding.canonicalBytes + Data([0])) }
        var nested = hello.canonicalBytes; nested[9] = 1 // inner start version cannot contradict the outer hello.
        #expect(throws: (any Error).self) { try ClusterNativeKeyHello(encoded: nested) }
        var suite = start.canonicalBytes
        let finiteDomainLength = Data("darkbloom/native-authorization/glm-finite-calibration/v1\0".utf8).count
        let closedOffset = 5 + finiteDomainLength + 16 + 8 + 6 * 32 + 16 + 8
        for offset in 0..<4 {
            suite = start.canonicalBytes; suite[closedOffset + offset] = 2
            #expect(throws: (any Error).self) { try ClusterNativeAuthorizationStart(encoded: suite) }
        }
        for key in [Data(repeating: 0, count: 32), Data(repeating: 255, count: 32),
                    Data([0xed]) + Data(repeating: 0xff, count: 30) + Data([0x7f])] {
            #expect(throws: (any Error).self) { try ClusterNativeKeyHello(start: start, publicKey: key) }
        }
    }
    @Test func finiteMalformedRequestExpiryDigestsAndRecordLimitsRefuse() throws {
        let original = try start(0).canonicalBytes
        let base = 5 + Data("darkbloom/native-authorization/glm-finite-calibration/v1\0".utf8).count
        let digests = base + 16 + 8
        let request = digests + 6 * 32
        let expiry = request + 16
        let frame = expiry + 8 + 4
        let plaintext = frame + 4
        let records = plaintext + 4
        let total = records + 8
        for range in [base..<(base + 16), digests..<(digests + 32), request..<(request + 16),
                      expiry..<(expiry + 8), frame..<(frame + 4), plaintext..<(plaintext + 4),
                      records..<(records + 8), total..<(total + 8)] {
            var changed = original
            changed.replaceSubrange(range, with: repeatElement(UInt8(0), count: range.count))
            #expect(throws: (any Error).self) { try ClusterNativeAuthorizationStart(encoded: changed) }
        }
        var overflow = original
        overflow[expiry] = 0xff // Cannot alias UInt64 into a negative Int64 expiry.
        #expect(throws: (any Error).self) { try ClusterNativeAuthorizationStart(encoded: overflow) }
        var equalDocuments = original
        equalDocuments.replaceSubrange((digests + 5 * 32)..<(digests + 6 * 32),
            with: original[(digests + 4 * 32)..<(digests + 5 * 32)])
        #expect(throws: (any Error).self) { try ClusterNativeAuthorizationStart(encoded: equalDocuments) }
    }
    @Test func finiteNonceReuseCannotCrossOwnerOrField() throws {
        let common = try common(), s0 = try start(0, common: common)
        #expect(throws: (any Error).self) {
            try ClusterNativeAuthorizationStart(common: common, rank: 1, ownerIncarnation: UUID(),
                leaseID: s0.leaseID, launchID: s0.leaseID)
        }
        // All corresponding fields differ; cross-field collision must still fail.
        let s1 = try ClusterNativeAuthorizationStart(common: common, rank: 1,
            ownerIncarnation: s0.leaseID, leaseID: UUID(), launchID: UUID())
        #expect(throws: (any Error).self) { try ClusterNativeKeyBinding(hellos: [hello(s0), hello(s1)]) }
    }
    @Test func servingV1RetainsThePublishedGoldenBytes() throws {
        func digest(_ i: Int) -> Data { Data(SHA256.hash(data: Data("fixture-native-field-\(i)".utf8))) }
        let common = try ClusterNativeAuthorizationCommon(
            epoch: UUID(uuidString: "01020304-0506-0708-090a-0b0c0d0e0f10")!,
            membershipGeneration: 7, nativePolicyGeneration: 11,
            membershipTranscriptSHA256: digest(0), approvedNativeBindingSHA256: digest(1),
            planSHA256: digest(2), artifactSHA256: digest(3), nativeRuntimeSHA256: digest(4),
            capabilitySHA256: digest(5), resourcePolicySHA256: digest(6), profileSHA256: digest(7),
            schedule: .oneChunkLookahead, maximumTransportFrameBytes: 4136,
            limits: ClusterRecordLimits(maximumPlaintextBytes: 4096, maximumRecordsPerDirection: 64,
                maximumCumulativePlaintextBytesPerDirection: 262144))
        let expected = "6461726b626c6f6f6d2f6e61746976652d617574686f72697a6174696f6e2f636f6d6d6f6e2f7631000102030405060708090a0b0c0d0e0f100000000000000007000000000000000b8ad475855361fdea5e55d4d25a1509a8bd642b6cd46b833911de616f35c259a216ae2c7dc747fc8ce4e9689e4a452ff4521715b2df90080271ccb8fb1cf621af23446f275f5bf8db1c3800edec9b9894e100ab11c066e2da3801b2ee8ec4e858115aeb8857c13d5ecd6019cee9924c70594c1b672a31f77b87794f22db84a7f3e4f23a1c268daffa06314ca0ed8e9750fc8993c955059c388fe2bd927ff669f6185fdc937e1cbcf6020851084ceafbdb4cb5e72b7d4fe7cad2fdd2e69161bc6a0b991f35b02833b15fd09df7db00e02a2f94f79457a156267d94fe7e415bff0e6c652e1114a1a09c419b0a491336f41b5ffbb58187b877c1b702b1945ac6c168010102000010280000100000000000000000400000000000040000"
        #expect(common.canonicalBytes.map { String(format: "%02x", $0) }.joined() == expected)
        let s0 = try start(0, common: common), s1 = try start(1, common: common)
        let binding = try ClusterNativeKeyBinding(hellos: [hello(s0), hello(s1)])
        #expect(binding.canonicalBytes[4] == 1)
        #expect(binding.canonicalBytes.count == ClusterNativeKeyBinding.encodedCount)
        #expect(try ClusterNativeKeyBinding(encoded: binding.canonicalBytes).canonicalBytes == binding.canonicalBytes)
    }
}
