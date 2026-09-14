import SandboxRuntime

public enum LumeExpiredLeaseReconciliationOutcome: Equatable, Sendable {
    case released
    case alreadyReleased
    case retained(String)
}

public struct LumeExpiredLeaseReconciliationResult: Equatable, Sendable {
    public let lease: SandboxCapacityLease
    public let outcome: LumeExpiredLeaseReconciliationOutcome

    public init(
        lease: SandboxCapacityLease,
        outcome: LumeExpiredLeaseReconciliationOutcome
    ) {
        self.lease = lease
        self.outcome = outcome
    }
}
