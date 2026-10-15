import Foundation
import MLXLMCommon
@testable import ProviderCore

/// Model-free lifecycle backend. Completion flags are fabricated explicitly;
/// this fixture never claims native, transport, signing, or resource evidence.
final class ProtectedMemberTestOwner: DistributedDeadlineExecutionOwner, @unchecked Sendable {
    let base = DistributedTestOwner()
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
        try reserve(request, identity: identity, profileID: profileID, capacityLimit: capacityLimit)
    }
    func shutdown() async { await base.shutdown() }
}

final class ProtectedMemberTestBackend: ProtectedMemberSessionBackend, @unchecked Sendable {
    let actualOwner = ProtectedMemberTestOwner()
    private let lock = NSLock(), terminal = NativePairSessionCompletionSignal()
    let drainGate = LocalHostLatch()
    var owner: any DistributedDeadlineExecutionOwner { actualOwner }
    var epoch: UUID { actualOwner.base.identity.membershipEpoch }
    let lifetime = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
    private var available = true, invalidated = false, spent = false, drainHeld = false
    private var cancels = 0, drains = 0
    var canAdmit: Bool { lock.withLock { available && !invalidated && !spent } }
    var invalid: Bool { lock.withLock { invalidated } }
    var exhausted: Bool { lock.withLock { spent } }
    var completion: NativePairSessionCompletion? { terminal.observation }
    var cancelCount: Int { lock.withLock { cancels } }
    var drainCount: Int { lock.withLock { drains } }
    func exhaust() { lock.withLock { spent = true } }
    func holdDrain() { lock.withLock { drainHeld = true } }
    func closeAdmissions() { lock.withLock { available = false } }
    func cancel() { lock.withLock { cancels += 1; available = false }; drainGate.complete() }
    func disconnect() { lock.withLock { invalidated = true }; actualOwner.base.losePeer() }
    func drain() async {
        let wait = lock.withLock { drains += 1; available = false; return drainHeld }
        if wait { await drainGate.wait() }
        await actualOwner.shutdown()
    }
    func publish(_ value: NativePairSessionCompletion? = nil) {
        terminal.complete(value ?? protectedCompletion(epoch))
    }
    func waitForCompletion() async -> NativePairSessionCompletion { await terminal.wait() }
}

func protectedCompletion(_ epoch: UUID, mask: Int = 127) -> NativePairSessionCompletion {
    .init(membershipEpoch: epoch, nativeCleanupObserved: mask & 1 != 0,
        ownerReleaseAcknowledged: mask & 2 != 0, ownerExitedNormally: mask & 4 != 0,
        requestTransportJoined: mask & 8 != 0, cancellationPublicationJoined: mask & 16 != 0,
        localReleasePublished: mask & 32 != 0, aggregateReleaseObserved: mask & 64 != 0)
}

func protectedTestSession(_ backend: ProtectedMemberTestBackend,
                          binding: ClusterStatusBinding? = nil,
                          validate: @escaping @Sendable () throws -> Void = {}) throws -> DistributedProtectedMemberSession {
    try .init(model: .init(publicModelID: "public/example", directory: URL(fileURLWithPath: "/fabricated"),
        modelType: "qwen3_5", eosTokenIDs: [], vocabularySize: 100),
        identity: backend.actualOwner.base.identity, profile: distributedTestProfile(), backend: backend,
        retainMemberLoop: UUID(), installedBinding: binding, validateInputs: validate)
}

func protectedTestBinding(_ backend: ProtectedMemberTestBackend, configurationPin: Character) throws -> ClusterStatusBinding {
    let id = backend.actualOwner.base.identity, pin = String(repeating: "a", count: 64)
    let object: [String: Any] = ["clusterID": "fixture-cluster", "memberID": id.peers[0].id, "role": "leader",
        "configurationSHA256": String(repeating: String(configurationPin), count: 64), "capabilitySHA256": pin,
        "publicModelID": "public/example", "runtimeModelID": id.modelID, "artifactSHA256": id.artifactSHA256,
        "configurationModelSHA256": id.configurationSHA256, "planSHA256": pin, "prefillSchedule": "serial_v1",
        "maximumLifetimeSeconds": 5, "maximumRequests": 1,
        "peers": id.peers.enumerated().map { ["id": $0.element.id, "rank": $0.offset,
            "runtimeBinarySHA256": $0.element.buildSHA256] as [String: Any] }]
    return try JSONDecoder().decode(ClusterStatusBinding.self, from: JSONSerialization.data(withJSONObject: object))
}

/// Synchronous validation can be paused from a detached startup task. Tests
/// release it on every path; async test methods never block on DispatchGroup.
final class ProtectedMemberValidationLatch: @unchecked Sendable {
    private let condition = NSCondition()
    private var count = 0, held = false, proceed = false
    let entered = LocalHostLatch()
    var rejectSecond = false
    func holdSecond() { condition.lock(); held = true; condition.unlock() }
    func check() throws {
        condition.lock(); defer { condition.unlock() }
        count += 1
        if count == 2 {
            entered.complete()
            while held && !proceed { condition.wait() }
            if rejectSecond { throw DistributedEngineError.unavailable }
        }
    }
    func release() { condition.lock(); proceed = true; condition.broadcast(); condition.unlock() }
}
