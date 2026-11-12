import CryptoKit
import Foundation

/// V2 commitment only. The existing NativeAuthorizationStart carries its hash
/// unchanged; decoding a member identity cannot confer coordinator authority.
struct NativePairTypedMembership: Sendable {
    var epoch: Data
    var generation: UInt64
    var model: String
    var suite: String
    var planSHA256: Data
    var proposedRuntimeBindingSHA256: Data
    var prepareBeforeUnixNano: Int64
    var expiresAtUnixNano: Int64
    var members: [NativeMemberIdentity]

    func digest() throws -> Data {
        guard epoch.count == 16, epoch.contains(where: { $0 != 0 }), generation != 0,
              !model.isEmpty, model.utf8.count <= 512, suite == "aes256gcm-hkdf-sha256-v1",
              planSHA256.count == 32, planSHA256.contains(where: { $0 != 0 }),
              proposedRuntimeBindingSHA256.count == 32, proposedRuntimeBindingSHA256.contains(where: { $0 != 0 }),
              prepareBeforeUnixNano > 0, expiresAtUnixNano >= prepareBeforeUnixNano, members.count == 2,
              members.contains(where: { if case .qualifiedAppAttest = $0.evidence { return true }; return false })
        else { throw NativeMemberIdentityError.invalid }
        var b = Data("darkbloom/coordinator-pair-membership/v2\0".utf8)
        func integer<T: FixedWidthInteger & UnsignedInteger>(_ value: T) {
            for shift in stride(from: T.bitWidth - 8, through: 0, by: -8) { b.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        func bytes(_ value: Data) { integer(UInt32(value.count)); b.append(value) }
        b.append(epoch); integer(generation); bytes(Data(model.utf8))
        b.append(planSHA256); b.append(proposedRuntimeBindingSHA256); bytes(Data(suite.utf8))
        integer(UInt64(prepareBeforeUnixNano)); integer(UInt64(expiresAtUnixNano))
        for (rank, member) in members.enumerated() { b.append(UInt8(rank)); bytes(try member.canonical()) }
        return Data(SHA256.hash(data: b))
    }
}
