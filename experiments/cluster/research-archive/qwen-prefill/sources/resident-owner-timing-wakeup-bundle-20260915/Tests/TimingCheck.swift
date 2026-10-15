import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

private func require(_ value: Bool, _ message: String) throws {
    guard value else { throw QualificationFailure.invalid(message) }
}
private func settingsObject(warmups: Int = 1, measured: Int = 3) throws -> [String: Any] {
    let frame = ClusterWorkerEventFrame(membershipEpoch: fixtureIdentity.membershipEpoch, sequence: 0, requestID: nil,
        event: .ready(.init(identity: fixtureIdentity, rank: 0, profile: fixtureProfile,
            executionPlanSHA256: fixturePlan, requestCapacityBytes: 1024)))
    let peer: [String: Any] = ["host": "127.0.0.1", "user": "fixture", "port": 22, "knownHostsFile": "/not-read/hosts",
        "identityFile": "/not-read/key", "installedOwner": "/not-launched/owner"]
    return ["schema": "darkbloom_owner_timing_cohort_v1", "cohortLabel": "invented", "policyLabel": "serial_v1",
        "cpuQualification": true, "clusterID": "invented", "readyTemplateBase64": try ClusterWorkerCodec.encode(frame).base64EncodedString(),
        "membershipEpoch": fixtureIdentity.membershipEpoch.uuidString.lowercased(), "peers": [peer, peer],
        "promptTokenIDs": [Int](repeating: 1, count: 8192), "stopTokenIDs": [Int](), "expectedTokenIDs": Array(9..<137),
        "outputCount": 128, "chunkSize": 512, "warmupCount": warmups, "measuredCount": measured,
        "lifetimeSeconds": 60, "startupSeconds": 5, "requestSeconds": 30]
}
private func settings(warmups: Int = 1, measured: Int = 3) throws -> TimingSettings {
    try TimingSettings.parse(JSONSerialization.data(withJSONObject: settingsObject(warmups: warmups, measured: measured)))
}
private struct Harness {
    let workers: [ClusterWorkerProcess], pair: ClusterWorkerPair
    let lifetime: UInt64
    init(_ executable: URL, behavior: String = "normal") throws {
        let now = DispatchTime.now().uptimeNanoseconds, end = now + 60_000_000_000; lifetime = end
        workers = try (0..<2).map { rank in
            try ClusterWorkerProcess(launch: .init(executable: executable, arguments: [String(rank), behavior], environment: [:]),
                expectedIdentity: fixtureIdentity, rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                startupDeadline: now + 5_000_000_000, lifetimeDeadline: end)
        }
        do { for worker in workers { try worker.launch() }; pair = try .init(workers: workers, startupDeadline: now + 5_000_000_000) }
        catch { for worker in workers { worker.fence() }; throw error }
    }
    func close() async throws {
        await pair.shutdown()
        try require(workers.allSatisfy(\.nativeCleanupObserved), "Actual owned-child exit proof missing")
    }
}

@MainActor @main struct TimingCheck {
    static func main() async throws {
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(90)
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        try qualificationEmit(["testing": "configurationAndTimestamps"]); try configuration(); try timestampOrder()
        try qualificationEmit(["testing": "fourRequests"]); try await fourRequests(executable)
        try qualificationEmit(["testing": "refusal"]); try await refusal(executable)
        try qualificationEmit(["testing": "wrongSequence"]); try await wrongSequence(executable)
        try qualificationEmit(["testing": "exhaustedLifetime"]); try await exhaustedLifetime(executable)
        try qualificationEmit(["testing": "failedPublication"]); try await failedPublication(executable)
        print("{\"groups\":7,\"passed\":true,\"actualLocalChildren\":true,\"modelOrNetwork\":false}")
        alarm(0)
    }
    static func configuration() throws {
        _ = try settings()
        for (key, value) in [("warmupCount", 2 as Any), ("measuredCount", 0), ("measuredCount", 4),
                             ("requestSeconds", 121), ("lifetimeSeconds", 301), ("chunkSize", 511),
                             ("warmupCount", true), ("measuredCount", 1.5), ("policyLabel", "unknown"),
                             ("expectedTokenIDs", [9]), ("extra", 1)] {
            var object = try settingsObject(); object[key] = value
            var rejected = false
            do { _ = try TimingSettings.parse(JSONSerialization.data(withJSONObject: object)) } catch { rejected = true }
            try require(rejected, "Invalid declared timing configuration was accepted: \(key)")
        }
    }
    static func timestampOrder() throws {
        let ids = Array(9..<137)
        var good = TimingObservation(requestID: UUID().uuidString, phase: "measured", iteration: 0, reserveBegan: 1,
            reserveCompleted: 2, startCalled: 3, firstToken: 4, finalToken: 5, finishedCallback: 6,
            retirementObserved: 7, resourcesReleased: 8, tokenIDs: ids, firstTokenCount: 1, finalTokenCount: 128,
            finishReason: "length", bytesInUseAfterRelease: 0)
        try good.validateCompleted(expected: ids)
        try require(good.internalOwnerControlFirstTokenNanoseconds == 1, "Wrong interval")
        for index in 0..<4 {
            var bad = good
            if index == 0 { bad.firstToken = 2 }; if index == 1 { bad.finalToken = 3 }
            if index == 2 { bad.retirementObserved = 5 }; if index == 3 { bad.finalTokenCount = 127 }
            var rejected = false; do { try bad.validateCompleted(expected: ids) } catch { rejected = true }
            try require(rejected, "Invalid timestamp/count observation was accepted")
        }
    }
    static func fourRequests(_ executable: URL) async throws {
        let h = try Harness(executable, behavior: "timed"); defer { for worker in h.workers { worker.fence() } }
        let pids = h.workers.map(\.launchedProcessIdentifier), cohort = TimingCohort(), config = try settings()
        var published = 0
        try await cohort.run(pair: h.pair, configuration: config, lifetimeDeadline: h.lifetime) { record in published += 1; try qualificationEmit(["testRequest": try record.object]) }
        let records = cohort.records, summary = timingSummary(records, warmups: 1, measured: 3)
        try require(records.count == 4 && published == 4 && Set(records.map(\.requestID)).count == 4,
                    "Four distinct fresh requests were not retained")
        try require(records.map(\.phase) == ["warmup", "measured", "measured", "measured"], "Warmup order differs")
        try require(records.allSatisfy { $0.completed && $0.sequenceGuardMatched && $0.bytesInUseAfterRelease == 0 }, "Incomplete timed request")
        try require(h.workers.map(\.launchedProcessIdentifier) == pids && h.workers.allSatisfy { !$0.nativeCleanupObserved }, "Workers reloaded or exited between requests")
        let measured = records.dropFirst().compactMap(\.internalOwnerControlFirstTokenNanoseconds).sorted()
        try require(summary["complete"] as? Bool == true && summary["measuredInternalOwnerControlFirstTokenNanoseconds"] as? [UInt64] == measured,
                    "Warmup contaminated measured intervals")
        try require(summary["medianInternalOwnerControlFirstTokenNanoseconds"] as? Double == Double(measured[1]), "Median differs")
        try await h.close()
    }
    static func refusal(_ executable: URL) async throws {
        let h = try Harness(executable, behavior: "refuse-second"); defer { for worker in h.workers { worker.fence() } }
        let cohort = TimingCohort(); var rejected = false
        do { try await cohort.run(pair: h.pair, configuration: settings(), lifetimeDeadline: h.lifetime) { _ in } } catch { rejected = true }
        try require(rejected && cohort.records.count == 2 && cohort.records[0].completed && !cohort.records[1].completed,
                    "Refusal was not retained or another request was attempted")
        let summary = timingSummary(cohort.records, warmups: 1, measured: 3)
        try require(summary["complete"] as? Bool == false && summary["medianInternalOwnerControlFirstTokenNanoseconds"] == nil, "Partial cohort published median")
        try await h.close()
    }
    static func wrongSequence(_ executable: URL) async throws {
        let h = try Harness(executable); defer { for worker in h.workers { worker.fence() } }
        var object = try settingsObject(warmups: 0, measured: 1); object["expectedTokenIDs"] = [Int](repeating: 1, count: 128)
        let config = try TimingSettings.parse(JSONSerialization.data(withJSONObject: object)), cohort = TimingCohort()
        var rejected = false
        do { try await cohort.run(pair: h.pair, configuration: config, lifetimeDeadline: h.lifetime) { _ in } } catch { rejected = true }
        try require(rejected && cohort.records.count == 1 && !cohort.records[0].completed && cohort.records[0].tokenIDs == [9], "Sequence mismatch not retained")
        try require(cohort.records[0].internalOwnerControlFirstTokenNanoseconds == nil, "Failed request produced a valid interval")
        try await h.close()
    }
    static func exhaustedLifetime(_ executable: URL) async throws {
        let h = try Harness(executable); defer { for worker in h.workers { worker.fence() } }
        let cohort = TimingCohort(); var rejected = false
        do { try await cohort.run(pair: h.pair, configuration: settings(), lifetimeDeadline: DispatchTime.now().uptimeNanoseconds - 1) { _ in } } catch { rejected = true }
        try require(rejected && cohort.records.count == 1 && cohort.records[0].startCalled == nil && h.pair.readiness != nil, "Expired cohort reserved or lost partial record")
        try await h.close()
    }
    static func failedPublication(_ executable: URL) async throws {
        let h = try Harness(executable); defer { for worker in h.workers { worker.fence() } }
        let cohort = TimingCohort(); var rejected = false
        do { try await cohort.run(pair: h.pair, configuration: settings(warmups: 0), lifetimeDeadline: h.lifetime) { _ in
            throw QualificationFailure.invalid("Invented output failure")
        } } catch { rejected = true }
        try require(rejected && cohort.records.count == 1 && cohort.records[0].bytesInUseAfterRelease == 0 && cohort.active == nil, "Publication failed before retirement or retried")
        try await h.close()
    }
}
