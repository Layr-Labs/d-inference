import Foundation
import MLXLMCommon
@testable import ProviderCore

/// Fabricated owner/session only: no child, model payload, remote network or MLX
/// evaluation. Actual HTTP tests use the real application and loopback listener.
final class LocalHostTestSession: DistributedLocalServerSession, @unchecked Sendable {
    let base = DistributedTestOwner()
    let profile = try! distributedTestProfile()
    let model = DistributedInstalledModel(publicModelID: "public/example", directory: URL(fileURLWithPath: "/fabricated"),
        modelType: "qwen3_5", eosTokenIDs: [99], vocabularySize: 100)
    let lock = NSLock()
    var phase: DistributedInstalledSessionStatus = .prepared
    var lifetime: UInt64?
    var validations = 0
    var starts = 0
    var stopCalled = false
    var nativeCleanup = false
    var holdOwnerACK = false
    var retainQuarantine = false
    var failSecondValidation = false
    var startDelay: Duration = .zero
    var lifetimeNanoseconds: UInt64 = 5_000_000_000
    var drainEntered = false
    var holdDrain = false
    private var exhausted = false
    let ack = LocalHostLatch(), drained = LocalHostLatch()
    var expectedIdentity: DistributedResidentIdentity { base.identity }
    var status: DistributedInstalledSessionStatus { lock.withLock { phase } }
    var httpAdmissionAvailable: Bool { lock.withLock { phase == .ready && !exhausted } }
    var httpSessionExhausted: Bool { lock.withLock { exhausted } }
    func exhaustRequests() { lock.withLock { exhausted = true } }
    var lifetimeDeadlineUptimeNanoseconds: UInt64? { lock.withLock { lifetime } }
    var nativeCleanupObserved: Bool { lock.withLock { nativeCleanup } }
    var validationCount: Int { lock.withLock { validations } }
    var startCount: Int { lock.withLock { starts } }
    var didEnterDrain: Bool { lock.withLock { drainEntered } }

    func validateModelInputs() throws {
        let reject = lock.withLock { validations += 1; return failSecondValidation && validations == 2 }
        if reject { throw DistributedEngineError.unavailable }
    }
    func start() async throws {
        lock.withLock { starts += 1; phase = .starting }
        if startDelay > .zero { try await Task.sleep(for: startDelay) }
        try Task.checkCancellation()
        lock.withLock { lifetime = DispatchTime.now().uptimeNanoseconds + lifetimeNanoseconds; phase = .ready }
    }
    func stop(until deadline: UInt64) async -> DistributedInstalledSessionStatus {
        lock.withLock { stopCalled = true; if phase != .released { phase = .stopping } }
        drained.complete()
        return status
    }
    func drain(until deadline: UInt64) async -> DistributedInstalledSessionStatus {
        let wait = lock.withLock { drainEntered = true; phase = .draining; return holdDrain }
        if wait { await drained.wait() }
        return status
    }
    func shutdown() async {
        let wait = lock.withLock { nativeCleanup = true; return holdOwnerACK }
        if wait { await ack.wait() }
        lock.withLock { phase = retainQuarantine ? .quarantined : .released }
    }
    func readiness() -> DistributedResidentReadiness? { status == .ready ? base.readiness() : nil }
    func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        base.setReadinessInvalidationHandler(handler)
    }
    func projectFirstToken(_ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission) -> CBv2FirstTokenProjectedWork {
        base.projectFirstToken(request, admission: admission)
    }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity,
                 profileID: String, capacityLimit: Int) throws -> any DistributedResidentRequestLease {
        try base.reserve(request, identity: identity, profileID: profileID, capacityLimit: capacityLimit)
    }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity,
                 profileID: String, capacityLimit: Int,
                 deadlineContext: DistributedRequestDeadlineContext) throws -> any DistributedResidentRequestLease {
        try reserve(request, identity: identity, profileID: profileID, capacityLimit: capacityLimit)
    }
}

final class LocalHostLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            let completed = lock.withLock { if done { return true }; waiters.append(continuation); return false }
            if completed { continuation.resume() }
        }
    }
    func complete() {
        let values = lock.withLock { done = true; let result = waiters; waiters.removeAll(); return result }
        for value in values { value.resume() }
    }
}

final class LocalHostDiscovery: @unchecked Sendable {
    private let lock = NSLock()
    private var record: LocalEndpoint.Info?
    private var writes = 0
    var value: LocalEndpoint.Info? { lock.withLock { record } }
    var writeCount: Int { lock.withLock { writes } }
    func replace(_ value: LocalEndpoint.Info) { lock.withLock { record = value } }
    var client: DistributedLocalDiscovery {
        .init(publish: { value in self.lock.withLock { self.record = value; self.writes += 1 } },
              removeIfOwned: { owned in
                  self.lock.withLock {
                      DistributedLocalDiscovery.remove(owned, read: { self.record }, remove: { self.record = nil })
                  }
              })
    }
}

func localHost(_ session: LocalHostTestSession, port: UInt16 = 0,
               discovery: LocalHostDiscovery? = nil) -> DistributedLocalServer {
    .init(session: session, config: .init(host: "127.0.0.1", port: port),
          tokenizerLoader: { _ in TokenizerHandle(DistributedTestTokenizer()) }, discovery: discovery?.client)
}

func localHostDeadline(_ milliseconds: UInt64 = 2_000) -> UInt64 {
    DispatchTime.now().uptimeNanoseconds + milliseconds * 1_000_000
}

func localHostEventually(_ predicate: () async -> Bool) async throws -> Bool {
    let end = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < end {
        if await predicate() { return true }
        try await Task.sleep(for: .milliseconds(5))
    }
    return await predicate()
}

func localHostGET(port: UInt16, path: String) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.timeoutInterval = 2
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, response as! HTTPURLResponse)
}

func localHostPOST(port: UInt16, model: String) async throws -> HTTPURLResponse {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
    request.httpMethod = "POST"; request.timeoutInterval = 2
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "model": model, "messages": [["role": "user", "content": "fixture"]], "stream": true])
    let (_, response) = try await URLSession.shared.data(for: request)
    return response as! HTTPURLResponse
}
