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
        lock.withLock { switch event { case .token(let id): tokens.append(id); case .finished(let value): finished = value }; return true }
    }
    func retire() { lock.withLock { retired = true } }
    var isRetired: Bool { lock.withLock { retired } }
    var valid: Bool { lock.withLock { tokens == [9, 10] && finished == .length } }
}
private struct Failure: Error {}
@main struct ProviderPipeContractTests {
    static func main() async throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[1]), deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        let workers = try (0..<2).map { rank in
            try ClusterWorkerProcess(launch: .init(executable: executable, arguments: [String(rank), "normal"], environment: [:]),
                expectedIdentity: fixtureIdentity, rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                startupDeadline: deadline, lifetimeDeadline: deadline + 15_000_000_000)
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
        guard owner.projectFirstToken(request, admission: .init()) == .unbounded else { throw Failure() }
        var bad = request; bad.sampling.temperature = 1
        var refused = false
        do { _ = try owner.reserve(bad, identity: ready.identity, profileID: profile.id, capacityLimit: 1800) } catch { refused = true }
        guard refused, owner.readiness() != nil else { throw Failure() }
        // Reusing a public CBv2 ID must still produce a fresh native UUID.
        for _ in 0..<2 {
            let lease = try owner.reserve(request, identity: ready.identity, profileID: profile.id, capacityLimit: 1800), events = Received()
            guard lease.requestID == request.id, lease.identity == ready.identity, lease.reservedBytes == 1600 else { throw Failure() }
            try lease.start { events.accept($0) }
            Task { await lease.waitUntilRetired(); events.retire() }
            let limit = ContinuousClock.now.advanced(by: .seconds(5))
            while !events.isRetired && ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(10)) }
            guard events.isRetired, events.valid else { throw Failure() }
            lease.releaseResources(); guard lease.bytesInUse == 0 else { throw Failure() }
        }
        await owner.shutdown()
        guard workers.allSatisfy(\.observedExit) else { throw Failure() }
        print("{\"passed\":true,\"actualProviderContractSource\":true,\"MLXValueStandins\":true,\"freshUUIDForReusedCBv2ID\":true,\"modelExecution\":false}")
    }
}
