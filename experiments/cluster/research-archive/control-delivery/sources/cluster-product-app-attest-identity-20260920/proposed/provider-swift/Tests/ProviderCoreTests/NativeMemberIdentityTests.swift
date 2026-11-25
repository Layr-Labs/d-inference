import Foundation
import Testing
@testable import ProviderCore

struct NativeMemberIdentityTests {
    let control = "BGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfU="
    let endpoint = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
    func fixture(_ evidence: NativeMemberIdentity.Evidence) throws -> NativeMemberIdentity {
        try NativeMemberIdentity(providerID: "member", controlPublicKey: control, processPublicKey: endpoint,
            binarySHA256: Data(repeating: 2, count: 32), metallibSHA256: Data(repeating: 3, count: 32), releasePolicyGeneration: 7, evidence: evidence)
    }
    @Test func identityKindsMatchGoCanonicalVectors() throws {
        let cases: [(NativeMemberIdentity.Evidence, String)] = [(.legacyMDA(serial: "serial"), "44424e49440101000000066d656d626572000000584247735830664c684c454a482b4c7a6d35574f6b51504a33413332424c65737a6f5053684f5558596d4d4b57542b4e43347634616635754f352b744b66412b654669764f4d3164724d56374f79375a416144652f5566553d0000002c415145424151454241514542415145424151454241514542415145424151454241514542415145424151453d0202020202020202020202020202020202020202020202020202020202020202030303030303030303030303030303030303030303030303030303030303030300000000000000070000000673657269616c"),
            (.qualifiedAppAttest(accountID: "account", machineID: "machine", credentialID: "credential", proofSessionID: "proof"), "44424e49440102000000066d656d626572000000584247735830664c684c454a482b4c7a6d35574f6b51504a33413332424c65737a6f5053684f5558596d4d4b57542b4e43347634616635754f352b744b66412b654669764f4d3164724d56374f79375a416144652f5566553d0000002c415145424151454241514542415145424151454241514542415145424151454241514542415145424151453d020202020202020202020202020202020202020202020202020202020202020203030303030303030303030303030303030303030303030303030303030303030000000000000007000000076163636f756e74000000076d616368696e650000000a63726564656e7469616c0000000570726f6f66")]
        for (evidence, expected) in cases {
            let identity = try fixture(evidence), bytes = try identity.canonical()
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            #expect(hex == expected)
            let decoded = try NativeMemberIdentity(canonical: bytes)
            #expect(decoded == identity)
        }
    }
    @Test func identityRejectsEveryTruncationAndSurplus() throws {
        for evidence in [NativeMemberIdentity.Evidence.legacyMDA(serial: "serial"), .qualifiedAppAttest(accountID: "account", machineID: "machine", credentialID: "credential", proofSessionID: "proof")] {
            let bytes = try fixture(evidence).canonical()
            for n in 0..<bytes.count { #expect(throws: (any Error).self) { try NativeMemberIdentity(canonical: Data(bytes.prefix(n))) } }
            var surplus = bytes; surplus.append(0)
            #expect(throws: (any Error).self) { try NativeMemberIdentity(canonical: surplus) }
            var unknown = bytes; unknown[6] = 3
            #expect(throws: (any Error).self) { try NativeMemberIdentity(canonical: unknown) }
            #expect(throws: (any Error).self) { try NativeMemberIdentity(canonical: Data(repeating: 1, count: 1025)) }
        }
    }
    @Test func identityRequiresActualVariantFieldsAndKey() throws {
        for bad in ["", String(repeating: "a", count: 129), "bad\n"] {
            #expect(throws: (any Error).self) { try fixture(.qualifiedAppAttest(accountID: "account", machineID: bad, credentialID: "credential", proofSessionID: "proof")) }
            #expect(throws: (any Error).self) { try fixture(.legacyMDA(serial: bad)) }
        }
        let identity = try fixture(.legacyMDA(serial: "serial"))
        let keyBytes = try #require(Data(base64Encoded: control))
        let alias = try NativeMemberIdentity(providerID: "member", controlPublicKey: Data(keyBytes.dropFirst()).base64EncodedString(), processPublicKey: endpoint,
            binarySHA256: identity.binarySHA256, metallibSHA256: identity.metallibSHA256, releasePolicyGeneration: 7, evidence: identity.evidence)
        let first = try identity.signingKeyIdentity(), second = try alias.signingKeyIdentity()
        #expect(first == second)
        #expect(throws: (any Error).self) {
            try NativeMemberIdentity(providerID: "member", controlPublicKey: endpoint, processPublicKey: endpoint,
                binarySHA256: identity.binarySHA256, metallibSHA256: identity.metallibSHA256, releasePolicyGeneration: 7, evidence: identity.evidence)
        }
    }
}
