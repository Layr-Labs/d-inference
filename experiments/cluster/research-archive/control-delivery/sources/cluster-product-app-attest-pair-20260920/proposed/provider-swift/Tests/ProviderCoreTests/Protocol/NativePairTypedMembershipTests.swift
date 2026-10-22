import Foundation
import Testing
@testable import ProviderCore

struct NativePairTypedMembershipTests {
    private func fixture(appOnly: Bool = false) throws -> NativePairTypedMembership {
        func member(_ evidence: NativeMemberIdentity.Evidence) throws -> NativeMemberIdentity {
            try NativeMemberIdentity(providerID: "member",
                controlPublicKey: "BGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfU=",
                processPublicKey: Data(repeating: 1, count: 32).base64EncodedString(),
                binarySHA256: Data(repeating: 2, count: 32), metallibSHA256: Data(repeating: 3, count: 32), releasePolicyGeneration: 7, evidence: evidence)
        }
        let app = NativeMemberIdentity.Evidence.qualifiedAppAttest(accountID: "account", machineID: "machine", credentialID: "credential", proofSessionID: "proof")
        return try NativePairTypedMembership(epoch: Data(repeating: 1, count: 16), generation: 9, model: "model", suite: "aes256gcm-hkdf-sha256-v1",
            planSHA256: Data(repeating: 4, count: 32), proposedRuntimeBindingSHA256: Data(repeating: 5, count: 32), prepareBeforeUnixNano: 100, expiresAtUnixNano: 200,
            members: [member(appOnly ? app : .legacyMDA(serial: "serial")), member(app)])
    }
    @Test func canonicalTypedMembershipMatchesGoVectors() throws {
        let mixed = try fixture().digest().map { String(format: "%02x", $0) }.joined()
        let app = try fixture(appOnly: true).digest().map { String(format: "%02x", $0) }.joined()
        #expect(mixed == "05472f9f7e8b3b84281dfeab49fc7b97d9d33d7b28548e53ee53bfd2c5566e17")
        #expect(app == "4d440df367756b3ca9ddab0028140f74b77a6971614dd8afccfdb85de81906af")
    }
    @Test func typedMembershipBindsRankConnectionAndPlan() throws {
        let original = try fixture().digest()
        var changed = try fixture(); changed.members.swapAt(0, 1)
        #expect(try changed.digest() != original)
        changed = try fixture(); changed.planSHA256[0] ^= 1
        #expect(try changed.digest() != original)
        changed = try fixture(); changed.epoch[0] ^= 1
        #expect(try changed.digest() != original)
        changed = try fixture(); changed.proposedRuntimeBindingSHA256[0] ^= 1
        #expect(try changed.digest() != original)
    }
    @Test func typedMembershipRejectsLegacyVersionAndInvalidBounds() throws {
        var legacy = try fixture(); legacy.members[1] = legacy.members[0]
        #expect(throws: NativeMemberIdentityError.self) { try legacy.digest() }
        var short = try fixture(); short.epoch.removeLast()
        #expect(throws: NativeMemberIdentityError.self) { try short.digest() }
        var expired = try fixture(); expired.expiresAtUnixNano = 99
        #expect(throws: NativeMemberIdentityError.self) { try expired.digest() }
        var surplus = try fixture(); surplus.members.append(surplus.members[0])
        #expect(throws: NativeMemberIdentityError.self) { try surplus.digest() }
    }
}
