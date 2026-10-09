import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Adversarial factory result: its base must never start when an old epoch is
/// supplied. All cleanup calls still act on the retained base obligation.
private final class RotationEpochSession: DistributedLocalServerSession, @unchecked Sendable {
    let base: LocalHostTestSession
    let expectedIdentity: DistributedResidentIdentity
    init(base: LocalHostTestSession, identity: DistributedResidentIdentity) { self.base = base; expectedIdentity = identity }
    var model: DistributedInstalledModel { base.model }
    var profile: DistributedResidentExecutionProfile { base.profile }
    var status: DistributedInstalledSessionStatus { base.status }
    var httpAdmissionAvailable: Bool { base.httpAdmissionAvailable }
    var httpSessionInvalid: Bool { base.httpSessionInvalid }
    var httpSessionExhausted: Bool { base.httpSessionExhausted }
    var lifetimeDeadlineUptimeNanoseconds: UInt64? { base.lifetimeDeadlineUptimeNanoseconds }
    func validateModelInputs() throws { try base.validateModelInputs() }
    func start() async throws { try await base.start() }
    func stop(until deadline: UInt64) async -> DistributedInstalledSessionStatus { await base.stop(until: deadline) }
    func drain(until deadline: UInt64) async -> DistributedInstalledSessionStatus { await base.drain(until: deadline) }
    func shutdown() async { await base.shutdown() }
    func readiness() -> DistributedResidentReadiness? { base.readiness() }
    func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void) { base.setReadinessInvalidationHandler(handler) }
    func projectFirstToken(_ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission) -> CBv2FirstTokenProjectedWork {
        base.projectFirstToken(request, admission: admission)
    }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity, profileID: String,
                 capacityLimit: Int) throws -> any DistributedResidentRequestLease {
        try base.reserve(request, identity: identity, profileID: profileID, capacityLimit: capacityLimit)
    }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity, profileID: String,
                 capacityLimit: Int, deadlineContext: DistributedRequestDeadlineContext) throws -> any DistributedResidentRequestLease {
        try base.reserve(request, identity: identity, profileID: profileID, capacityLimit: capacityLimit, deadlineContext: deadlineContext)
    }
}

@Test func distributedLocalRotationRejectsThirdGenerationABA() async throws {
    let first = LocalHostTestSession(), second = LocalHostTestSession(), third = LocalHostTestSession()
    let repeated = RotationEpochSession(base: third, identity: first.expectedIdentity)
    let factory = RotationTestFactory([first, second, repeated]), host = factory.host()
    try await host.start(); first.exhaustRequests()
    #expect(try await localHostEventually {
        let status = await host.status
        return second.startCount == 1 && status.phase == .serving
    })
    second.exhaustRequests()
    #expect(try await localHostEventually { await host.status.cleanupComplete })
    let final = await host.status
    let retained = await host.generation
    #expect(final.failed && factory.count == 2 && third.startCount == 0 && third.status == .released)
    #expect(retained.session === repeated)
    #expect(await host.seenMembershipEpochs == [first.expectedIdentity.membershipEpoch, second.expectedIdentity.membershipEpoch])
}

@Test func distributedLocalRotationRejectsChangedInstalledBindingBeforeStart() async throws {
    let first = LocalHostTestSession(), second = LocalHostTestSession()
    first.observation = try rotationObservation(first, configurationPin: "a")
    second.observation = try rotationObservation(second, configurationPin: "b")
    let factory = RotationTestFactory([first, second]), host = factory.host()
    try await host.start(); first.exhaustRequests()
    #expect(try await localHostEventually { await host.status.cleanupComplete })
    let final = await host.status, retained = await host.generation
    #expect(final.failed && factory.count == 1 && second.startCount == 0 && second.status == .released)
    #expect(retained.session === second)
}

@Test func distributedLocalRotationRejectsAlreadyStartedFactoryResult() async throws {
    let first = LocalHostTestSession(), second = LocalHostTestSession()
    second.phase = .ready // Deliberate factory contract violation; no child is claimed.
    let factory = RotationTestFactory([first, second]), host = factory.host()
    try await host.start(); first.exhaustRequests()
    #expect(try await localHostEventually { await host.status.cleanupComplete })
    let final = await host.status, retained = await host.generation
    #expect(final.failed && factory.count == 1 && second.startCount == 0 && second.status == .released)
    #expect(retained.session === second)
}

private func rotationObservation(_ session: LocalHostTestSession, configurationPin: Character) throws -> ClusterSessionObservation {
    let pin = String(repeating: "a", count: 64)
    let object: [String: Any] = ["clusterID": "fixture-cluster", "memberID": session.expectedIdentity.peers[0].id,
        "role": "leader", "configurationSHA256": String(repeating: String(configurationPin), count: 64), "capabilitySHA256": pin,
        "publicModelID": session.model.publicModelID, "runtimeModelID": session.expectedIdentity.modelID,
        "artifactSHA256": pin, "configurationModelSHA256": pin, "planSHA256": pin,
        "prefillSchedule": "serial_v1", "maximumLifetimeSeconds": 10, "maximumRequests": 16,
        "peers": session.expectedIdentity.peers.enumerated().map { rank, peer in
            ["id": peer.id, "rank": rank, "runtimeBinarySHA256": peer.buildSHA256] as [String: Any]
        }]
    let binding = try JSONDecoder().decode(ClusterStatusBinding.self, from: JSONSerialization.data(withJSONObject: object))
    return .init(binding: binding, phase: "prepared", observedMembershipEpoch: nil, observedPrefillSchedule: nil,
        ready: false, admission: nil, members: [], mtpEnabled: false, mtpOffReason: "fixture")
}
