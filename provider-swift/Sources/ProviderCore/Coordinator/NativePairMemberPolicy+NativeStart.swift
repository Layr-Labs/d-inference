import CryptoKit
import Foundation
import DarkbloomClusterSecurity

// Native start verification shares the one canonical saved-policy reader. It
// lives apart so the reader itself needs no cluster security module and the
// saved-setup checks can compile it alone.
extension NativePairMemberPolicy {
    /// `plan`: the plan a cluster approval's session must run, the one this
    /// member derived and registered (a cluster approval fixes no plan, only
    /// its placement policy). Nil skips that comparison for a cluster
    /// approval, whose caller then compares the plan itself; a pair approval
    /// always compares its own fixed plan.
    func require(_ start: ClusterNativeAuthorizationStart, plan: Data? = nil) throws {
        let c = start.common
        guard case .servingV1(let serving) = c.permission else { throw NativePairMemberError.binding }
        let expectedPlan = cluster == nil ? hashes[0] : (plan ?? c.planSHA256)
        guard serving.nativePolicyGeneration == generation, serving.approvedNativeBindingSHA256 == Data(SHA256.hash(data: bytes)),
              [c.planSHA256, c.artifactSHA256, serving.nativeRuntimeSHA256, serving.capabilitySHA256,
               serving.resourcePolicySHA256, c.profileSHA256] == [expectedPlan, hashes[1], hashes[2], hashes[5], hashes[6], hashes[7]],
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
