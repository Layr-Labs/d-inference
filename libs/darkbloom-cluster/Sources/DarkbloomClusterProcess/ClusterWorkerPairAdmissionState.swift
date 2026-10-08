import Foundation

public struct ClusterWorkerPairAdmissionState: Sendable, Equatable {
    public let remainingLifetimeNanoseconds: UInt64
    public let admissionsRemaining: Int
    public let hasActiveRequest: Bool
    public let isDraining: Bool
    public let isValid: Bool

    /// A caller's explicit minimum budget is an admission requirement, not a
    /// predicted completion time. The actual reserve still revalidates it.
    public func canAdmit(minimumRemainingNanoseconds: UInt64 = 1) -> Bool {
        isValid && !hasActiveRequest && admissionsRemaining > 0 && minimumRemainingNanoseconds > 0
            && remainingLifetimeNanoseconds >= minimumRemainingNanoseconds
    }
}
