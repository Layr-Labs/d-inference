import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import MLXLMCommon
import ProviderPipeContract

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [Int] = []
    private var finished: CBv2FinishReason?
    private var retired = false
    func accept(_ event: DistributedResidentEvent) -> Bool {
        lock.withLock {
            switch event { case .token(let id), .loggedToken(let id, _): tokens.append(id); case .finished(let value): finished = value; case .promptCache, .telemetry: break }
            return true
        }
    }
    func retire() { lock.withLock { retired = true } }
    var isRetired: Bool { lock.withLock { retired } }
    var valid: Bool { lock.withLock { tokens == [9, 10] && finished == .length } }
    var seenTokens: [Int] { lock.withLock { tokens } }
    var finish: CBv2FinishReason? { lock.withLock { finished } }
}
private struct Failure: Error {}
@main struct ProviderPipeContractTests {
    static func main() async throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[1]), deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        let workers = try (0..<2).map { rank in
            try ClusterWorkerProcess(launch: .init(executable: executable, arguments: [String(rank), "normal"],
                    // The third reservation is the sampled one: it must reach both ranks with its sampling.
                    environment: ["TEST_SAMPLED_FROM_RESERVATION": "3"]),
                expectedIdentity: fixtureIdentity, rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                startupDeadline: deadline, initialLeaseDeadline: deadline + 15_000_000_000)
        }
        defer { for worker in workers { worker.fence() } }
        for worker in workers { try worker.launch() }
        let pair = try ClusterWorkerPair(workers: workers, startupDeadline: deadline)
        let profile = try DistributedResidentExecutionProfile(id: fixtureProfile.id, vocabularySize: fixtureProfile.vocabularySize,
            maxPromptTokens: fixtureProfile.maximumPromptTokens, maxOutputTokens: fixtureProfile.maximumOutputTokens,
            maxContextTokens: fixtureProfile.maximumContextTokens, requestTimeout: .seconds(10))
        let owner: any DistributedResidentExecutionOwner = try DistributedPipeExecutionOwner(pair: pair, profile: profile, chunkSize: 2)
        guard let ready = owner.readiness() else { throw Failure() }
        let request = CBv2Request(id: .init(7), promptTokens: [1, 2, 3], sampling: .init(temperature: 0), maxTokens: 2)
        guard owner.projectFirstToken(request, admission: .init()) == .unbounded(reason: nil) else { throw Failure() }
        var bad = request; bad.sampling.topLogprobs = 21 // above OpenAI's 20; 1...20 are served
        var refused = false
        do { _ = try owner.reserve(bad, identity: ready.identity, profileID: profile.id, capacityLimit: 1800) }
        catch DistributedEngineError.refused(.logprobsUnsupported) { refused = true }
        guard refused, owner.readiness() != nil else { throw Failure() }
        // A stochastic request without a resolved seed never reaches a worker.
        var unseeded = request; unseeded.sampling.temperature = 0.7
        refused = false
        do { _ = try owner.reserve(unseeded, identity: ready.identity, profileID: profile.id, capacityLimit: 1800) }
        catch DistributedEngineError.refused(.invalidSampling) { refused = true }
        guard refused, owner.readiness() != nil else { throw Failure() }
        // Sampled (resolved seed) and receipt-carrying requests reach both
        // workers, whose codec and session accept the sampling field.
        var sampled = request; sampled.sampling.temperature = 0.7; sampled.sampling.topK = 20; sampled.sampling.seed = 42
        sampled.sampling.logitBias = [3: -1]; sampled.prefixCacheReceiptID = .init(99)
        // Reusing a public CBv2 ID must still produce a fresh native UUID.
        for value in [request, request, sampled] {
            let lease = try owner.reserve(value, identity: ready.identity, profileID: profile.id, capacityLimit: 1800), events = Received()
            guard lease.requestID == value.id, lease.identity == ready.identity, lease.reservedBytes == 1600 else { throw Failure() }
            try lease.start { events.accept($0) }
            Task { await lease.waitUntilRetired(); events.retire() }
            let limit = ContinuousClock.now.advanced(by: .seconds(5))
            while !events.isRetired && ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(10)) }
            guard events.isRetired, events.valid else { throw Failure() }
            lease.releaseResources(); guard lease.bytesInUse == 0 else { throw Failure() }
        }
        await owner.shutdown()
        guard workers.allSatisfy(\.observedExit) else { throw Failure() }
        try await abortedRequest(executable)
        print("{\"passed\":true,\"actualProviderContractSource\":true,\"MLXValueStandins\":true,\"freshUUIDForReusedCBv2ID\":true,\"prefixReceiptServed\":true,\"sampledReservation\":true,\"abortedForMemory\":true,\"modelExecution\":false}")
    }

    /// D6: a request both ranks ended for rank 1's memory reaches the engine
    /// as the pair's capacity refusal (`token_budget_exhausted`, the words of
    /// `refusedForCapacity`), after the token it already had, which the
    /// bridge answers with the memory 503 or a typed stream error. The owner
    /// stays ready and serves the next request.
    static func abortedRequest(_ executable: URL) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        let workers = try (0..<2).map { rank in
            try ClusterWorkerProcess(launch: .init(executable: executable, arguments: [String(rank), "abort-once"], environment: [:]),
                expectedIdentity: fixtureIdentity, rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                startupDeadline: deadline, initialLeaseDeadline: deadline + 15_000_000_000)
        }
        defer { for worker in workers { worker.fence() } }
        for worker in workers { try worker.launch() }
        let pair = try ClusterWorkerPair(workers: workers, startupDeadline: deadline)
        let profile = try DistributedResidentExecutionProfile(id: fixtureProfile.id, vocabularySize: fixtureProfile.vocabularySize,
            maxPromptTokens: fixtureProfile.maximumPromptTokens, maxOutputTokens: fixtureProfile.maximumOutputTokens,
            maxContextTokens: fixtureProfile.maximumContextTokens, requestTimeout: .seconds(10))
        let owner: any DistributedResidentExecutionOwner = try DistributedPipeExecutionOwner(pair: pair, profile: profile, chunkSize: 2)
        guard let ready = owner.readiness() else { throw Failure() }
        let request = CBv2Request(id: .init(8), promptTokens: [1, 2, 3], sampling: .init(temperature: 0), maxTokens: 2)
        for attempt in 0..<2 {
            let lease = try owner.reserve(request, identity: ready.identity, profileID: profile.id, capacityLimit: 1800)
            let events = Received()
            // As the engine does on every failure: the lease is cancelled at its terminal.
            try lease.start { event in
                let more = events.accept(event)
                if case .finished(.error) = event { lease.cancel() }
                return more
            }
            Task { await lease.waitUntilRetired(); events.retire() }
            let limit = ContinuousClock.now.advanced(by: .seconds(5))
            while !events.isRetired && ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(10)) }
            guard events.isRetired else { throw Failure() }
            if attempt == 0 {
                guard events.seenTokens == [9], case .error(let message)? = events.finish,
                      message.hasPrefix("token_budget_exhausted: request requires 5 context tokens but only "),
                      message.contains(" available on this cluster pair now"),
                      message.contains("rank 1's memory refused it while it ran") else { throw Failure() }
            } else {
                guard events.valid else { throw Failure() }
            }
            lease.releaseResources()
            guard owner.readiness() != nil, pair.admissionState.isValid else { throw Failure() }
        }
        await owner.shutdown()
        guard workers.allSatisfy(\.observedExit) else { throw Failure() }
    }
}
