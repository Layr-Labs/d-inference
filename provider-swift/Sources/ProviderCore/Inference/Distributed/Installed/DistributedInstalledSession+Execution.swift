import Foundation
import MLXLMCommon

extension DistributedInstalledSession: DistributedDeadlineExecutionOwner {
    public func readiness() -> DistributedResidentReadiness? { (try? activeOwner())?.readiness() }
    public func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void) { installInvalidationHandler(handler) }
    public func projectFirstToken(_ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission) -> CBv2FirstTokenProjectedWork {
        (try? activeOwner())?.projectFirstToken(request, admission: admission) ?? .unbounded
    }
    public func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity,
                        profileID: String, capacityLimit: Int) throws -> any DistributedResidentRequestLease {
        try activeOwner(forReservation: true).reserve(request, identity: identity, profileID: profileID, capacityLimit: capacityLimit)
    }
    public func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity, profileID: String,
                        capacityLimit: Int, deadlineContext: DistributedRequestDeadlineContext) throws -> any DistributedResidentRequestLease {
        try activeOwner(forReservation: true).reserve(request, identity: identity, profileID: profileID,
            capacityLimit: capacityLimit, deadlineContext: deadlineContext)
    }
    public func shutdown() async { await waitForStop() }
}
