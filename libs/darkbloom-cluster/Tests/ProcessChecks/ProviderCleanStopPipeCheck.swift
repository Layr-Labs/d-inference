import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import MLXLMCommon
import ProviderPipeContract

/// The clean stop through the provider's actual pipe lease: a stop the
/// consumer asked for (declined token, or `requestCleanStop`) is a natural
/// stop and keeps the owner ready; a stop the owner made because it is
/// stopping is reported as cancelled, not as a natural end.
private struct Failure: Error { let message: String }
private func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [Int] = []
    private var finished: CBv2FinishReason?
    func accept(_ event: DistributedResidentEvent) {
        lock.withLock { switch event { case .token(let id): tokens.append(id); case .finished(let value): finished = value } }
    }
    var values: ([Int], CBv2FinishReason?) { lock.withLock { (tokens, finished) } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func set() { lock.withLock { raised = true } }
    var value: Bool { lock.withLock { raised } }
}

@main struct ProviderCleanStopPipeCheck {
    static func owner(_ executable: URL, cleanStopWait: UInt64) throws -> ([ClusterWorkerProcess], any DistributedResidentExecutionOwner) {
        let now = DispatchTime.now().uptimeNanoseconds, startup = now + 5_000_000_000
        let workers = try (0..<2).map { rank in
            try ClusterWorkerProcess(launch: .init(executable: executable, arguments: [String(rank), rank == 0 ? "normal" : "clean-stop"], environment: [:]),
                expectedIdentity: fixtureIdentity, rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                startupDeadline: startup, lifetimeDeadline: now + 30_000_000_000)
        }
        for worker in workers { try worker.launch() }
        let pair = try ClusterWorkerPair(workers: workers, startupDeadline: startup, timing: .init(admissionWaitNanoseconds: 5_000_000_000,
            shutdownAcknowledgementNanoseconds: 2_000_000_000, cleanStopWaitNanoseconds: cleanStopWait))
        let profile = try DistributedResidentExecutionProfile(id: fixtureProfile.id, vocabularySize: fixtureProfile.vocabularySize,
            maxPromptTokens: fixtureProfile.maximumPromptTokens, maxOutputTokens: fixtureProfile.maximumOutputTokens,
            maxContextTokens: fixtureProfile.maximumContextTokens, requestTimeout: .seconds(20))
        return (workers, try DistributedPipeExecutionOwner(pair: pair, profile: profile, chunkSize: 2))
    }
    static func awaitRetired(_ lease: any DistributedResidentRequestLease) async throws {
        let flag = Flag()
        Task { await lease.waitUntilRetired(); flag.set() }
        let limit = ContinuousClock.now.advanced(by: .seconds(6))
        while !flag.value && ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(10)) }
        try require(flag.value, "the lease did not retire")
    }

    static func main() async throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let request = CBv2Request(id: .init(11), promptTokens: [1, 2, 3], sampling: .init(temperature: 0), maxTokens: 4)

        // The consumer asks for the clean stop (it went away), then declines a
        // token on the next request: both are natural stops, the owner stays ready.
        do {
            let (workers, owner) = try owner(executable, cleanStopWait: 0)
            defer { for worker in workers { worker.fence() } }
            let identity = owner.readiness()!.identity
            let lease = try owner.reserve(request, identity: identity, profileID: fixtureProfile.id, capacityLimit: 1800)
            let events = Received()
            try lease.start { event in
                events.accept(event)
                if case .token = event, events.values.0.count == 2 { _ = lease.requestCleanStop() }
                return true
            }
            try await awaitRetired(lease); lease.releaseResources()
            try require(events.values.0 == [9, 10] && events.values.1 == .stop,
                        "a consumer's clean stop was not a natural stop at the next token: \(events.values)")
            try require(!lease.requestCleanStop(), "a retired lease accepted a clean stop")
            try require(owner.readiness() != nil && workers.allSatisfy({ !$0.observedExit }), "the consumer's clean stop gave up the owner")
            let next = try owner.reserve(request, identity: identity, profileID: fixtureProfile.id, capacityLimit: 1800), declined = Received()
            try next.start { declined.accept($0); if case .token = $0 { return false }; return true }
            try await awaitRetired(next); next.releaseResources()
            try require(declined.values.0 == [9] && declined.values.1 == .stop, "a declined token was not a natural stop: \(declined.values)")
            await owner.shutdown()
            try require(workers.allSatisfy { $0.termination == .exited(0) && $0.sentSignals.isEmpty }, "the ranks did not end by shutdown")
        }

        // The owner stops while a request is running: the request ends at its
        // next token and the consumer is told it was cancelled.
        do {
            let (workers, owner) = try owner(executable, cleanStopWait: 3_000_000_000)
            defer { for worker in workers { worker.fence() } }
            let identity = owner.readiness()!.identity
            let lease = try owner.reserve(request, identity: identity, profileID: fixtureProfile.id, capacityLimit: 1800)
            let events = Received(), entered = DispatchSemaphore(value: 0)
            try lease.start { event in
                events.accept(event)
                if case .token = event, events.values.0.count == 1 { entered.signal(); usleep(300_000) }
                return true
            }
            let began = await withCheckedContinuation { c in
                DispatchQueue.global().async { c.resume(returning: entered.wait(timeout: .now() + 3) == .success) }
            }
            try require(began, "the first token never arrived")
            await owner.shutdown()
            try require(events.values.0 == [9] && events.values.1 == .cancelled,
                        "an owner's stop was reported as \(String(describing: events.values.1)), not as cancelled")
            try require(workers.allSatisfy { $0.termination == .exited(0) && $0.sentSignals.isEmpty }, "the ranks did not end by shutdown")
        }
        print("{\"passed\":true,\"groups\":2,\"actualProviderLeaseSource\":true,\"cleanStop\":true,\"modelExecution\":false}")
    }
}
