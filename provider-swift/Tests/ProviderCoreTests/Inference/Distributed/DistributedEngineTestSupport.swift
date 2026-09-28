import Foundation
import MLXLMCommon
@testable import ProviderCore

final class DistributedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
    var clock: CBv2Clock { CBv2Clock { self.now } }
}

final class DistributedTestLease: DistributedResidentRequestLease, @unchecked Sendable {
    let identity: DistributedResidentIdentity
    let requestID: CBv2RequestID
    let reservedBytes: Int
    private let lock = NSLock()
    private let acknowledgement = DistributedRetirementLatch()
    private var emit: (@Sendable (DistributedResidentEvent) -> Bool)?
    private var starts = 0
    private var cancels = 0
    private var releases = 0
    var throwOnStart = false

    init(identity: DistributedResidentIdentity, requestID: CBv2RequestID, reservedBytes: Int = 64) {
        self.identity = identity
        self.requestID = requestID
        self.reservedBytes = reservedBytes
    }

    var bytesInUse: Int { 0 } // fabricated owner; no native residency is measured
    var startCount: Int { lock.withLock { starts } }
    var cancelCount: Int { lock.withLock { cancels } }
    var releaseCount: Int { lock.withLock { releases } }

    func start(emit: @escaping @Sendable (DistributedResidentEvent) -> Bool) throws {
        lock.withLock { starts += 1; self.emit = emit }
        if throwOnStart { throw DistributedEngineError.unavailable }
    }
    func cancel() { lock.withLock { cancels += 1 } }
    func waitUntilRetired() async { await acknowledgement.wait() }
    func releaseResources() { lock.withLock { releases += 1; emit = nil } }
    func acknowledge() { acknowledgement.complete() }
    @discardableResult func send(_ event: DistributedResidentEvent) -> Bool {
        let callback = lock.withLock { emit }
        return callback?(event) ?? false
    }
}

final class DistributedTestOwner: DistributedResidentExecutionOwner, @unchecked Sendable {
    private let lock = NSLock()
    let identity = DistributedResidentIdentity(
        membershipEpoch: UUID(), modelID: "fabricated-qwen-9b",
        artifactSHA256: String(repeating: "a", count: 64),
        configurationSHA256: String(repeating: "b", count: 64), peers: [
            .init(id: "peer0", buildSHA256: String(repeating: "c", count: 64)),
            .init(id: "peer1", buildSHA256: String(repeating: "d", count: 64))
        ])
    var available = true
    var capacityBytes = 1024
    var profileID = "fabricated-greedy"
    var projection: CBv2FirstTokenProjectedWork = .bounded(
        work: .init(prefillTokens: 3, decodeTokens: 1, scheduledSteps: 2, mixedSteps: 0),
        serviceDuration: .seconds(1))
    var onReserve: (@Sendable () -> Void)?
    var badReservationIdentity = false
    var throwOnStart = false
    private var invalidation: (@Sendable () -> Void)?
    private var leases: [DistributedTestLease] = []
    private var shutdowns = 0

    var last: DistributedTestLease { lock.withLock { leases.last! } }
    var reserveCount: Int { lock.withLock { leases.count } }
    var shutdownCount: Int { lock.withLock { shutdowns } }

    func readiness() -> DistributedResidentReadiness? {
        lock.withLock {
            available ? .init(identity: identity, profileID: profileID, requestCapacityBytes: capacityBytes) : nil
        }
    }
    func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { invalidation = handler }
    }
    func projectFirstToken(
        _ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission
    ) -> CBv2FirstTokenProjectedWork {
        lock.withLock { projection }
    }
    func reserve(
        _ request: CBv2Request, identity: DistributedResidentIdentity,
        profileID: String, capacityLimit: Int
    ) throws -> any DistributedResidentRequestLease {
        guard identity == self.identity, profileID == self.profileID, available, capacityLimit >= 64 else {
            throw DistributedEngineError.unavailable
        }
        var returnedIdentity = identity
        if badReservationIdentity {
            returnedIdentity = .init(
                membershipEpoch: UUID(), modelID: identity.modelID,
                artifactSHA256: identity.artifactSHA256,
                configurationSHA256: identity.configurationSHA256, peers: identity.peers)
        }
        let lease = DistributedTestLease(identity: returnedIdentity, requestID: request.id)
        lease.throwOnStart = throwOnStart
        lock.withLock { leases.append(lease) }
        onReserve?()
        return lease
    }
    func shutdown() async { lock.withLock { shutdowns += 1 } }
    func losePeer(notify: Bool = true) {
        let callback = lock.withLock { available = false; return invalidation }
        if notify { callback?() }
    }
}

final class DistributedTestDetokenizers: CBv2DetokenizerFactory {
    final class Decoder: CBv2IncrementalDetokenizer {
        let holdback: StopHoldback
        private(set) var matchedStopString = false
        init(_ stops: [String]) { holdback = StopHoldback(stopStrings: stops) }
        func push(_ tokens: [Int]) -> String {
            let result = holdback.ingest(tokens.map { "t\($0)" }.joined())
            matchedStopString = result.stopped
            return result.text
        }
        func flush() -> String { matchedStopString ? "" : holdback.flush() }
    }
    func makeDetokenizer(stopStrings: [String]) -> any CBv2IncrementalDetokenizer { Decoder(stopStrings) }
}

func distributedTestProfile(maxPrompt: Int = 8192, maxOutput: Int = 128) throws -> DistributedResidentExecutionProfile {
    try .init(
        id: "fabricated-greedy", vocabularySize: 100, maxPromptTokens: maxPrompt,
        maxOutputTokens: maxOutput, maxContextTokens: maxPrompt + maxOutput, requestTimeout: .seconds(315))
}

func distributedTestEngine(
    _ owner: DistributedTestOwner, clock: CBv2Clock = .continuous
) throws -> DistributedCBv2Engine {
    try .init(
        owner: owner, expectedIdentity: owner.identity, profile: distributedTestProfile(),
        detokenizers: DistributedTestDetokenizers(), clock: clock)
}

func distributedTestRequest(_ id: UInt64 = 1, maxTokens: Int = 2) -> CBv2Request {
    .init(id: .init(id), promptTokens: [1, 2, 3], sampling: .init(temperature: 0), maxTokens: maxTokens)
}

func distributedTestDeadline(_ instant: ContinuousClock.Instant) -> CBv2FirstTokenDeadlineAdmission {
    .init(deadline: instant, conservativePrefillTokensPerSecond: 100, conservativeDecodeTokensPerSecond: 100)
}

func distributedCollect(_ stream: AsyncStream<CBv2Event>) async -> [CBv2Event] {
    var events: [CBv2Event] = []
    for await event in stream { events.append(event) }
    return events
}

func distributedTerminal(_ events: [CBv2Event]) -> (CBv2FinishReason, CBv2Usage)? {
    guard let last = events.last, case .finished(let reason, let usage) = last else { return nil }
    return (reason, usage)
}

func distributedText(_ events: [CBv2Event]) -> String {
    events.reduce(into: "") { text, event in
        if case .delta(let delta, _, _) = event { text += delta }
    }
}

struct DistributedTestTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1, 2, 3] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tokenIds.map { "t\($0)" }.joined() }
    func convertTokenToId(_ token: String) -> Int? { token == "</s>" ? 99 : nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { "</s>" }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [1, 2, 3] }
}
