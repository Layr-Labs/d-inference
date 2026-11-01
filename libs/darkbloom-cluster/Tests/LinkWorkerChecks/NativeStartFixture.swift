import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity

/// Committed native starts for the fixture membership (both ranks, one
/// common), as a member would be handed them for the combined profile.
/// Fixture digests only; nothing here is approval.
func fixtureNativeStarts(epoch: UUID = fixtureIdentity.membershipEpoch) throws -> [ClusterNativeAuthorizationStart] {
    func digest(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }
    func bytes(_ hex: String) -> Data {
        var result = Data(), index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16)!); index = next
        }
        return result
    }
    let limits = try ClusterRecordLimits(maximumPlaintextBytes: 1 << 20)
    let common = try ClusterNativeAuthorizationCommon(epoch: epoch, membershipGeneration: 1, nativePolicyGeneration: 1,
        membershipTranscriptSHA256: digest(0x11), approvedNativeBindingSHA256: digest(0x12),
        planSHA256: bytes(fixturePlan), artifactSHA256: bytes(fixtureIdentity.artifactSHA256),
        nativeRuntimeSHA256: digest(0x13), capabilitySHA256: digest(0x14), resourcePolicySHA256: digest(0x15),
        profileSHA256: digest(0x16), schedule: .serial, maximumTransportFrameBytes: (1 << 20) + 40, limits: limits)
    return try (0...1).map { try .init(common: common, rank: $0, ownerIncarnation: UUID(), leaseID: UUID(), launchID: UUID()) }
}
