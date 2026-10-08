import Foundation

struct Gemma4MTPRemoteTargetReceipt: Encodable {
    let policy = "gemma4_mtp_remote_target_resources_v1"
    let budgetSHA256: String, requestSHA256: String
    let baseTerms: [Gemma4MTPRemoteTargetBudget.Term]
    let verificationTerms: [Gemma4MTPRemoteTargetBudget.Term]
    let baseNativeBytes: Int, verificationNativeBytes: Int, hostBytes: Int
    let observations: Int, minimumActualFreeBytes: Int, maximumObservedActiveBytes: Int
    let assistantLoadedOnTarget = false, servingFloorChanged = false
    let wholeProcessPeakBoundEstablished = false, physicalRetirementEstablished = false
}

/// Additive ledger attached to the existing target resource owner. It never
/// samples/adopts a separate observation or creates a model/request/device owner.
final class Gemma4MTPRemoteTargetResources {
    struct Reservation { let revision: Int, nativeBytes: Int, hostBytes: Int }
    let budget: Gemma4MTPRemoteTargetBudget
    let deadline: UInt64
    private var attached = false, failed = false
    private var revision = 0, observedRevision = -1
    private var verification: [String:Gemma4MTPRemoteTargetBudget.Term] = [:]
    private var verificationBytes = 0
    private var observations = 0, minimumFree = Int.max, maximumActive = 0
    init(budget: Gemma4MTPRemoteTargetBudget, deadline: UInt64) throws {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline, deadline-now <= 300_000_000_000,
              try budget.terms.allSatisfy({ try QwenResidentResourceEnvironment.allocationBound($0.logicalBytes) == $0.allocationBound }) else {
            throw ProbeError("Remote target requires actual allocator bounds and original absolute lifetime")
        }
        self.budget = budget; self.deadline = deadline
    }
    func attach(deadline: UInt64, requestSHA256: String, maximumFrontier: Int) throws {
        guard !attached, !failed, self.deadline == deadline,
              budget.requestSHA256 == requestSHA256, budget.maximumFrontier == maximumFrontier else {
            throw ProbeError("Remote target attachment differs from original resource owner")
        }
        attached = true; revision += 1
    }
    func requireLive() throws {
        guard !failed, attached, DispatchTime.now().uptimeNanoseconds < deadline else {
            throw ProbeError("Remote target additive resource scope failed or expired")
        }
    }
    func reservation() throws -> Reservation {
        try requireLive()
        return .init(revision:revision,nativeBytes:try QwenLongPrefillCheckedBytes.sum(
            [budget.nativeBytes,verificationBytes]),hostBytes:budget.hostBytes)
    }
    func acceptedObservation(_ value: Reservation, os: QwenDenseStageLoadOSObservation,
                             native: QwenDenseStageLoadNativeObservation) throws {
        try requireLive()
        guard value.revision == revision, os.pressureLevel == 1 else { throw ProbeError("Remote target observation is stale") }
        observedRevision = revision; observations += 1
        minimumFree = min(minimumFree,os.actualFreeBytes); maximumActive = max(maximumActive,native.activeBytes)
    }
    private func requireObserved() throws {
        try requireLive()
        guard observedRevision == revision else { throw ProbeError("Remote target operation lacks its summed original-owner observation") }
    }
    /// Scalar revision/attachment/deadline validation only. No resource values
    /// are cached here; the original owner freshly admits each control boundary.
    func checkControlLifetime() throws {
        do { try requireObserved() }
        catch { poison(); throw error }
    }
    func requireSerialTargetHead() throws {
        try requireObserved()
        guard budget.serialTargetHead else {
            throw ProbeError("Serial target head lacks its original-owner additive allowance")
        }
    }
    func admitVerification(_ plan: CBv2AttentionVerificationPlan) throws {
        try requireObserved()
        guard plan.layout.layers.count == 30, plan.layout.layers.map(\.globalIndex) == Array(0..<30),
              plan.layout.maximumTokens == budget.maximumFrontier+1,
              Set(plan.captureLayerIndices) == [28,29], (1...3).contains(plan.steps) else {
            throw ProbeError("Remote target verification differs from actual full Gemma owner")
        }
        var next = verification
        // Invocation-local scalar reuse; each named array remains separately charged.
        var allocationBounds = InvocationAllocationBoundMemo()
        for item in plan.additionalArrays {
            let bound = try allocationBounds.value(for:item.bytes,
                resolve:QwenResidentResourceEnvironment.allocationBound)
            if bound > (next[item.name]?.allocationBound ?? 0) {
                next[item.name] = .init(name:item.name,logicalBytes:item.bytes,allocationBound:bound)
            }
        }
        // Cache only the checked structural sum; no observation is retained.
        let total = try QwenLongPrefillCheckedBytes.sum(next.values.map(\.allocationBound))
        verification = next; verificationBytes = total; revision += 1
        // Original owner must check this NEW revision before actual state work.
        // No per-window/reconcile discount: old views and current graphs overlap.
    }
    func admitSend(_ plan: Gemma4MTPPullTransferPlan) throws {
        try requireObserved()
        let reserved = Dictionary(uniqueKeysWithValues:budget.terms.map { ($0.name,$0) })
        guard plan.frontier <= budget.maximumFrontier else { throw ProbeError("Remote target transfer exceeds admitted frontier") }
        for item in plan.senderAdditional {
            guard let term = reserved[item.name], item.bytes <= term.logicalBytes,
                  try QwenResidentResourceEnvironment.allocationBound(item.bytes) <= term.allocationBound else {
                throw ProbeError("Remote target transfer pack lacks its original summed allocation allowance")
            }
        }
    }
    func receipt() throws -> Gemma4MTPRemoteTargetReceipt {
        try requireObserved()
        let values = verification.values.sorted { $0.name < $1.name }
        return .init(budgetSHA256:budget.fingerprint,requestSHA256:budget.requestSHA256,baseTerms:budget.terms,
            verificationTerms:values,baseNativeBytes:budget.nativeBytes,
            verificationNativeBytes:verificationBytes,hostBytes:budget.hostBytes,
            observations:observations,minimumActualFreeBytes:minimumFree,maximumObservedActiveBytes:maximumActive)
    }
    func poison() { failed = true }
}
