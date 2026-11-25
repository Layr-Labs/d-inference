import Foundation
import Testing
@testable import ProviderCore

@Suite struct NativePairIntentTests {
    private func fixture(rank: UInt8 = 0) throws -> NativePairIntent {
        try NativePairIntent(clusterID: "cluster-fixture", approvalID: "approved-fixture", policySHA256: Data(repeating: 0x11, count: 32),
            memberIDs: ["member-0", "member-1"], signerSHA256: [Data(repeating: 0x22, count: 32), Data(repeating: 0x33, count: 32)], rank: rank)
    }
    @Test func intentCanonicalMatchesIndependentGoVectorAndHasSeparateSigningDomain() throws {
        let p = try fixture(), raw = try p.canonical()
        let expected = "44424e4943010000000f636c75737465722d6669787475726500000010617070726f7665642d666978747572651111111111111111111111111111111111111111111111111111111111111111000000086d656d6265722d302222222222222222222222222222222222222222222222222222222222222222000000086d656d6265722d313333333333333333333333333333333333333333333333333333333333333333000000012c"
        #expect(raw.map { String(format: "%02x", $0) }.joined() == expected)
        #expect(try NativePairIntent(raw) == p)
        let m = try NativePairIntentMessage(nonce: String(repeating: "a", count: 64), sequence: 1, intent: p)
        let signed = try m.signingBytes()
        #expect(signed.starts(with: Data("darkbloom/coordinator-native-pair/configuration-intent/v1\0".utf8)))
        #expect(!signed.starts(with: Data("darkbloom/coordinator-native-pair/member-message/v1\0".utf8)))
        #expect(throws: NativePairMemberError.self) { try fixture(rank: 2) }
    }
    @Test func intentTruncationAndAmbiguousFieldsRefuse() throws {
        let p = try fixture(), raw = try p.canonical()
        for n in 0..<raw.count { #expect(throws: NativePairMemberError.self) { try NativePairIntent(raw.prefix(n)) } }
        #expect(throws: NativePairMemberError.self) { try NativePairIntent(raw + Data([0])) }
        let m = try NativePairIntentMessage(nonce: String(repeating: "a", count: 64), sequence: 1, intent: p, signature: Data(repeating: 1, count: 8))
        let wire = try JSONEncoder().encode(m), text = String(decoding: wire, as: UTF8.self)
        _ = try NativePairIntentMessage.decode(wire)
        for malformed in [text + "\n", text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1"), text.replacingOccurrences(of: "\"version\":1", with: "\"version\":null"), text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"approved\":true")] {
            #expect(throws: (any Error).self) { try NativePairIntentMessage.decode(Data(malformed.utf8)) }
        }
    }
}
