import CryptoKit
import Foundation
import DarkbloomClusterSecurity

// Native start verification shares the one canonical saved-policy reader.
extension NativePairMemberPolicy {
    func require(_ start: ClusterNativeAuthorizationStart) throws {
        let c = start.common
        guard c.nativePolicyGeneration == generation, c.approvedNativeBindingSHA256 == Data(SHA256.hash(data: bytes)),
              [c.planSHA256, c.artifactSHA256, c.nativeRuntimeSHA256, c.capabilitySHA256,
               c.resourcePolicySHA256, c.profileSHA256] == [hashes[0], hashes[1], hashes[2], hashes[5], hashes[6], hashes[7]],
              c.schedule.rawValue == schedule, c.maximumTransportFrameBytes == Int(maximumFrame),
              c.limits.maximumPlaintextBytes == Int(maximumPlaintext), c.limits.maximumRecordsPerDirection == maximumRecords,
              c.limits.maximumCumulativePlaintextBytesPerDirection == maximumCumulative else { throw NativePairMemberError.binding }
    }
    static func preparation(_ payload: Data) throws -> (Self, ClusterNativeAuthorizationStart) {
        var r = Reader(payload); try r.literal(Data([68, 66, 78, 80, 82, 1]))
        let count = try r.integer(UInt32.self)
        guard count <= 8192 else { throw NativePairMemberError.binding }
        let policy = try Self(r.read(Int(count)))
        let start = try ClusterNativeAuthorizationStart(encoded: r.read(r.remaining))
        try policy.require(start)
        return (policy, start)
    }
}
