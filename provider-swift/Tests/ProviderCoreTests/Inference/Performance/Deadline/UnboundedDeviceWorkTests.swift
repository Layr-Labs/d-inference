import Testing
@testable import ProviderCore

@Test func unboundedDeviceWorkInvalidatesOldEvidenceWithoutChargingResources() throws {
    let budget = WholeMacServiceBudget()
    #expect(budget.acquire(ownerID: "target", concurrency: 4,
        work: .init(modelID: "model", profileID: "profile", promptTokens: 128, maxOutputTokens: 32)))
    let before = try #require(budget.calibrationSnapshot(ownerID: "target", modelID: "model", profileID: "profile"))
    let vision = budget.beginUnboundedActivity()
    #expect(!before.evidenceGuard.isValid)
    #expect(budget.usedFraction == 0.25 && budget.count == 1)
    #expect(budget.calibrationSnapshot(ownerID: "target", modelID: "model", profileID: "profile") == nil)
    let wire = budget.snapshot(slotEpochs: ["model": "epoch", "other": "other-epoch"],
        profileIDs: ["model": "profile"])
    #expect(wire.deadlineWorkByModel["model"]?.known == false)
    #expect(wire.deadlineWorkByModel["other"]?.known == false)
    let loading = budget.beginUnboundedActivity()
    vision.finish()
    vision.finish() // A repeated cleanup cannot retire a later owner.
    #expect(!budget.deadlineWork(modelID: "model", epoch: "epoch").known)
    loading.finish()
    #expect(budget.deadlineWork(modelID: "model", epoch: "epoch").known)
    let after = try #require(budget.calibrationSnapshot(ownerID: "target", modelID: "model", profileID: "profile"))
    #expect(after.evidenceGuard.isValid && !before.evidenceGuard.isValid)
    budget.release(ownerID: "target")
}

@Test func unboundedDeviceWorkHandoffStaysUnknownUntilMultimodalRetirement() throws {
    let budget = WholeMacServiceBudget()
    #expect(budget.acquire(ownerID: "target", concurrency: 4,
        work: .init(modelID: "model", profileID: "profile", promptTokens: 128, maxOutputTokens: 32)))
    let preparation = budget.beginUnboundedActivity()
    // The bridge takes its ordinary charged lease before the preparer exits.
    #expect(budget.acquire(ownerID: "media", concurrency: 4,
        work: .init(modelID: "vlm", profileID: nil, promptTokens: 128, maxOutputTokens: 32)))
    preparation.finish()
    #expect(budget.usedFraction == 0.5)
    #expect(budget.calibrationSnapshot(ownerID: "target", modelID: "model", profileID: "profile") == nil)
    #expect(!budget.deadlineWork(modelID: "vlm", epoch: "media-epoch").known)
    // Consumer terminal/cancellation does not release this ownership. The
    // actual retirement callback owns the existing release call below.
    budget.release(ownerID: "media")
    #expect(budget.calibrationSnapshot(ownerID: "target", modelID: "model", profileID: "profile") != nil)
    budget.release(ownerID: "target")
}

@Test func unboundedDeviceWorkScopeUnwindsOnFailure() throws {
    struct PreparationFailure: Error {}
    let budget = WholeMacServiceBudget()
    func prepare() throws {
        let activity = budget.beginUnboundedActivity()
        defer { activity.finish() }
        #expect(!budget.deadlineWork(modelID: "model", epoch: "epoch").known)
        throw PreparationFailure()
    }
    #expect(throws: PreparationFailure.self) { try prepare() }
    #expect(budget.deadlineWork(modelID: "model", epoch: "epoch").known)
    #expect(budget.usedFraction == 0 && budget.count == 0)
}
