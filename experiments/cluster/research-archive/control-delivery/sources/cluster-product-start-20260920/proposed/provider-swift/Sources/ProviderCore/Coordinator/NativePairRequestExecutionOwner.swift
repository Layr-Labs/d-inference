import Foundation
import MLXLMCommon
import DarkbloomClusterProcess

/// Thin fixed-workload gate before the unchanged bilateral owner reserves any
/// state or consumes its one experimental request slot. It owns no process.
public final class NativePairRequestExecutionOwner: DistributedDeadlineExecutionOwner, @unchecked Sendable {
    private let owner: DistributedPipeExecutionOwner
    private let pair: ClusterWorkerPair
    init(_ owner: DistributedPipeExecutionOwner, pair: ClusterWorkerPair) {self.owner=owner; self.pair=pair}
    var admissionState: ClusterWorkerPairAdmissionState { pair.admissionState }
    func closeAdmissions() { pair.stopAcceptingRequests() }
    func drain() async { await pair.drainAndShutdown() }
    public func readiness() -> DistributedResidentReadiness? {owner.readiness()}
    public func setReadinessInvalidationHandler(_ handler:@escaping @Sendable ()->Void) {owner.setReadinessInvalidationHandler(handler)}
    public func projectFirstToken(_ request:CBv2Request,admission:CBv2FirstTokenDeadlineAdmission)->CBv2FirstTokenProjectedWork {
        owner.projectFirstToken(request,admission:admission) // remains unbounded until measured
    }
    private func require(_ request: CBv2Request) throws { try ProtectedLocalWorkload.require(request) }
    public func reserve(_ request:CBv2Request,identity:DistributedResidentIdentity,profileID:String,capacityLimit:Int) throws -> any DistributedResidentRequestLease {
        try require(request)
        return try owner.reserve(request,identity:identity,profileID:profileID,capacityLimit:capacityLimit)
    }
    public func reserve(_ request:CBv2Request,identity:DistributedResidentIdentity,profileID:String,capacityLimit:Int,
                        deadlineContext:DistributedRequestDeadlineContext) throws -> any DistributedResidentRequestLease {
        try require(request)
        return try owner.reserve(request,identity:identity,profileID:profileID,capacityLimit:capacityLimit,deadlineContext:deadlineContext)
    }
    public func shutdown() async {await owner.shutdown()}
}
