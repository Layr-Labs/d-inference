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
    ///
    /// `runtime`: the runtime block this member's own saved setup gives
    /// (contract M3), read only for a model approval, which pins no runtime.
    /// Nil skips that comparison for a model approval, whose caller then
    /// compares the runtime itself; an approval that pins a runtime always
    /// compares its own.
    func require(_ start: ClusterNativeAuthorizationStart, plan: Data? = nil, runtime own: ClusterPlan.Runtime? = nil) throws {
        let c = start.common
        guard case .servingV1(let serving) = c.permission else { throw NativePairMemberError.binding }
        let expectedPlan = cluster == nil ? pinnedPlan : (plan ?? c.planSHA256)
        let started = ClusterPlan.Runtime(nativeRuntimeSHA256: Self.hex(serving.nativeRuntimeSHA256),
            capabilitySHA256: Self.hex(serving.capabilitySHA256), resourcePolicySHA256: Self.hex(serving.resourcePolicySHA256),
            profileSHA256: Self.hex(c.profileSHA256))
        guard serving.nativePolicyGeneration == generation, serving.approvedNativeBindingSHA256 == Data(SHA256.hash(data: bytes)),
              c.planSHA256 == expectedPlan, c.artifactSHA256 == artifact, (runtime?.block ?? own ?? started) == started,
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
