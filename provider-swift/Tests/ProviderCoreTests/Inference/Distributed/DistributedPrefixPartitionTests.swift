import Foundation
import MLXLMCommon
import Testing
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
@testable import ProviderCore

/// A rank that admits every reservation, gives it back when cancelled, and
/// records each reservation it was sent with the command line a worker would
/// read for it. No process, model or GPU.
private final class RecordingRank: ClusterWorkerEndpoint, @unchecked Sendable {
    static let identity = ClusterWorkerIdentity(membershipEpoch: UUID(), modelID: "fabricated-qwen-9b",
        artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: String(repeating: "b", count: 64),
        peers: [.init(id: "peer0", buildSHA256: String(repeating: "c", count: 64)),
                .init(id: "peer1", buildSHA256: String(repeating: "d", count: 64))])
    /// `distributedTestProfile()` as the workers state it.
    static let profile = ClusterWorkerProfile(id: "fabricated-greedy", vocabularySize: 100, maximumPromptTokens: 8192,
        maximumOutputTokens: 128, maximumChunkTokens: 64, maximumContextTokens: 8192 + 128)
    static let plan = String(repeating: "e", count: 64)
    let expectedIdentity = RecordingRank.identity
    let expectedProfile = RecordingRank.profile
    let executionPlanSHA256 = RecordingRank.plan
    let rank: Int
    let readiness: ClusterWorkerReady?
    var localLifetimeDeadlineUptimeNanoseconds: UInt64 { .max }
    var nativeCleanupObserved: Bool { lock.withLock { cleaned } }
    private let lock = NSLock()
    private let arrived = DispatchSemaphore(value: 0)
    private var events: [ClusterWorkerEventFrame] = []
    private var sequence: UInt64 = 0
    private var cleaned = false
    private var sent: [(value: ClusterWorkerReservation, line: String)] = []
    var reservations: [(value: ClusterWorkerReservation, line: String)] { lock.withLock { sent } }

    init(rank: Int) {
        let ready = ClusterWorkerReady(identity: Self.identity, rank: rank, profile: Self.profile,
            executionPlanSHA256: Self.plan, requestCapacityBytes: 1 << 20)
        self.rank = rank; readiness = ready
        enqueue(nil, .ready(ready))
    }

    private func enqueue(_ requestID: UUID?, _ event: ClusterWorkerEvent) {
        lock.withLock {
            events.append(.init(membershipEpoch: Self.identity.membershipEpoch, sequence: sequence,
                requestID: requestID, event: event))
            sequence += 1
        }
        arrived.signal()
    }

    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {}
    func sendWorkerCommand(_ command: ClusterWorkerCommand, requestID: UUID?, deadline: UInt64) throws {
        switch command {
        case .reserve(let value):
            let line = try ClusterWorkerCodec.encode(.init(membershipEpoch: Self.identity.membershipEpoch,
                sequence: 1, requestID: requestID, command: command))
            lock.withLock { sent.append((value, String(decoding: line, as: UTF8.self))) }
            enqueue(requestID, .admitted(reservedBytes: min(64, value.capacityLimitBytes)))
        case .cancel: enqueue(requestID, .retired(.cancelled))
        case .shutdown:
            lock.withLock { cleaned = true }
            enqueue(nil, .shutdownComplete)
        default: throw ClusterWorkerOwnerError.invalid("not scripted")
        }
    }
    func receiveWorkerEvent(until deadline: UInt64, cancelled: () -> Bool) throws -> ClusterWorkerEventFrame {
        while true {
            if let next = lock.withLock({ events.isEmpty ? nil : events.removeFirst() }) { return next }
            guard DispatchTime.now().uptimeNanoseconds < deadline, !cancelled() else { throw ClusterWorkerOwnerError.deadline }
            _ = arrived.wait(timeout: .now() + .milliseconds(5))
        }
    }
    func requestNativeCleanup() { lock.withLock { cleaned = true } }
    func waitForNativeCleanup() { while !nativeCleanupObserved { Thread.sleep(forTimeInterval: 0.001) } }
    func waitUntilNativeCleanup() async {
        while !nativeCleanupObserved { try? await Task.sleep(for: .milliseconds(1)) }
    }
}

/// The pair's owner (`DistributedPipeExecutionOwner`) gives both ranks each
/// request's own prompt-prefix partition, from the fields the single-Mac
/// engine keys and gates its caches by: the real owner and worker pair over
/// two scripted ranks.
@Suite("Distributed prefix partition", .serialized, .timeLimit(.minutes(1)))
struct DistributedPrefixPartitionTests {
    @Test func bothRanksAreGivenTheRequestsPartitionAndNeverItsSalt() async throws {
        let ranks = [RecordingRank(rank: 0), RecordingRank(rank: 1)]
        let pair = try ClusterWorkerPair(workers: ranks,
            startupDeadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
        let profile = try distributedTestProfile()
        let owner = try DistributedPipeExecutionOwner(pair: pair, profile: profile, chunkSize: 16)
        let identity = try #require(owner.readiness()?.identity)
        let salt = "authenticated-tenant-scope-7f3c"
        let cases: [(enabled: Bool, salt: String?, expected: ClusterWorkerPrefixCache?)] = [
            // A local request: cache on, no tenant; the reservation's bytes are the earlier ones.
            (true, nil, nil),
            // A remote request without an authenticated scope.
            (false, nil, .disabled),
            // Cache off wins over a salt.
            (false, salt, .disabled),
            (true, salt, .tenant(ClusterWorkerPrefixCache.tenantDigest(salt: salt))),
        ]
        for (index, value) in cases.enumerated() {
            let request = CBv2Request(id: .init(UInt64(index + 1)), promptTokens: [1, 2, 3],
                sampling: .init(temperature: 0), maxTokens: 2, cacheSalt: value.salt, prefixCacheEnabled: value.enabled)
            let lease = try owner.reserve(request, identity: identity, profileID: profile.id, capacityLimit: 1 << 20)
            lease.cancel()
            await lease.waitUntilRetired()
            lease.releaseResources()
            for rank in ranks {
                #expect(rank.reservations.count == index + 1)
                let sent = try #require(rank.reservations.last)
                #expect(sent.value.prefixCache == value.expected, "case \(index), rank \(rank.rank)")
                #expect(sent.line.contains("\"prefixCache\"") == (value.expected != nil), "case \(index), rank \(rank.rank)")
                #expect(!sent.line.contains(salt), "case \(index), rank \(rank.rank)")
                if case .tenant(let digest)? = value.expected { #expect(sent.line.contains(digest)) }
            }
        }
        await owner.shutdown()
    }
}
