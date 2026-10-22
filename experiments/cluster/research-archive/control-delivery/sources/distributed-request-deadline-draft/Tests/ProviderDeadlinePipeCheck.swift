import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import MLXLMCommon
import ProviderDeadlineContract

private struct Failure: Error { let message: String }
private func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }

@main struct ProviderDeadlinePipeCheck {
    static func main() async throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        for slow in [false, true] {
            let now = DispatchTime.now().uptimeNanoseconds
            let lifetime = now + 5_000_000_000
            let workers = try (0..<2).map { rank in
                try ClusterWorkerProcess(launch: .init(executable: executable,
                    arguments: [String(rank), slow ? "slow-admit" : "normal"],
                    environment: ["TEST_MAX_DEADLINE": String(lifetime), "TEST_MIN_REMAINING": "1000000000"]),
                    expectedIdentity: fixtureIdentity, rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                    startupDeadline: now + 2_000_000_000, lifetimeDeadline: lifetime + UInt64(rank) * 1_000_000_000)
            }
            defer { for worker in workers { worker.fence() } }
            for worker in workers { try worker.launch() }
            let pair = try ClusterWorkerPair(workers: workers, startupDeadline: now + 2_000_000_000)
            try require(pair.localLifetimeDeadlineUptimeNanoseconds == lifetime, "wrong minimum lifetime")
            let profile = try DistributedResidentExecutionProfile(id: fixtureProfile.id,
                vocabularySize: fixtureProfile.vocabularySize, maxPromptTokens: fixtureProfile.maximumPromptTokens,
                maxOutputTokens: fixtureProfile.maximumOutputTokens, maxContextTokens: fixtureProfile.maximumContextTokens,
                requestTimeout: .seconds(20)) // Deliberately larger than both worker lifetimes.
            let owner: any DistributedDeadlineExecutionOwner = try DistributedPipeExecutionOwner(pair: pair, profile: profile, chunkSize: 2)
            let identity = owner.readiness()!.identity
            let request = CBv2Request(id: .init(7), promptTokens: [1, 2, 3], sampling: .init(temperature: 0), maxTokens: 2)
            do {
                _ = try owner.reserve(request, identity: identity, profileID: profile.id, capacityLimit: 1800,
                    deadlineContext: .init(generationDeadline: ContinuousClock.now))
                throw Failure(message: "expired origin admitted")
            } catch DistributedRequestDeadlineError.generationExpired { }
            try require(owner.readiness() != nil, "pre-reserve expiry poisoned idle workers")
            let first = ContinuousClock.now.advanced(by: slow ? .milliseconds(30) : .seconds(1))
            let context = DistributedRequestDeadlineContext(generationDeadline: ContinuousClock.now.advanced(by: .seconds(20)),
                                                           firstTokenDeadline: first)
            if slow {
                let began = ContinuousClock.now
                do {
                    _ = try owner.reserve(request, identity: identity, profileID: profile.id,
                        capacityLimit: 1800, deadlineContext: context)
                    throw Failure(message: "slow reserve ignored first-token admission cap")
                } catch ClusterWorkerOwnerError.deadline { }
                try require(began.duration(to: .now) < .seconds(4), "admission cleanup exceeded bound")
                try require(workers.allSatisfy(\.observedExit), "reserve threw before actual fences")
            } else {
                let lease = try owner.reserve(request, identity: identity, profileID: profile.id,
                                              capacityLimit: 1800, deadlineContext: context)
                try require(lease.reservedBytes == 1600, "lifetime clamp prevented valid admission")
                // Child verified wire generation remains >1 s, not the shorter
                // admission/TTFT budget. No forward is requested by this fixture.
                lease.cancel(); await lease.waitUntilRetired(); lease.releaseResources()
                try require(lease.bytesInUse == 0, "request resources remain after retirement")
            }
            await owner.shutdown()
            try require(workers.allSatisfy(\.observedExit), "shutdown lacked actual child exit")
        }
        print("{\"passed\":true,\"actualLocalPipeChildren\":4,\"actualProviderOwnerSource\":true,\"modelOrNetworkExecution\":false}")
    }
}
