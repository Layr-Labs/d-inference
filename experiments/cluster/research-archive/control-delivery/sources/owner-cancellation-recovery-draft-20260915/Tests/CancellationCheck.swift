import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

func require(_ value: Bool, _ message: String) throws {
    guard value else { throw QualificationFailure.invalid(message) }
}
func fixtureSettingsObject(_ selected: CancellationCase = .startedBeforeFirstToken) throws -> [String: Any] {
    let epoch = UUID(), ready = ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: 0, requestID: nil,
        event: .ready(.init(identity: fixtureIdentity(epoch), rank: 0, profile: fixtureProfile,
            executionPlanSHA256: fixturePlan, requestCapacityBytes: 1024)))
    let peer: [String: Any] = ["host": "127.0.0.1", "user": "fixture", "port": 22,
        "knownHostsFile": "/not-read/known-hosts", "identityFile": "/not-read/key", "installedOwner": "/not-launched/owner"]
    return ["schema": "darkbloom_owner_cancellation_recovery_v1", "clusterID": "fixture",
        "cancellationCase": selected.rawValue, "cancellationEpoch": epoch.uuidString.lowercased(),
        "recoveryEpoch": UUID().uuidString.lowercased(), "peers": [peer, peer],
        "readyTemplateBase64": try ClusterWorkerCodec.encode(ready).base64EncodedString(),
        "promptTokenIDs": [Int](repeating: 1, count: 8192), "expectedTokenIDs": Array(9..<137),
        "lifetimeSeconds": 30, "startupSeconds": 5, "requestSeconds": 10, "beforeFirstDelayMilliseconds": 150]
}
func fixtureSettings(_ selected: CancellationCase = .startedBeforeFirstToken) throws -> CancellationSettings {
    try CancellationSettings.parse(JSONSerialization.data(withJSONObject: fixtureSettingsObject(selected)))
}

@MainActor final class FixtureFactory {
    let executable: URL, directory: URL
    let lifetime = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
    var groups: [[ClusterWorkerProcess]] = [], epochs: [UUID] = [], openedAt: [UInt64] = []
    var missingFirstACK = false, delayedACK = false, badRecovery = false, fastFirst = false, staleRecovery = false
    var firstACKObservedAt: UInt64?
    init(executable: URL, directory: URL) { self.executable = executable; self.directory = directory }
    func open(_ epoch: UUID, selected: CancellationCase) throws -> CancellationOwnedPair {
        let index = groups.count
        let actualEpoch = staleRecovery && index == 1 ? epochs[0] : epoch
        let now = DispatchTime.now().uptimeNanoseconds
        let behavior = index == 1 ? (badRecovery ? "wrong-recovery" : "recovery")
            : fastFirst ? "fast" : selected == .startedBeforeFirstToken ? "before-first" : "after-decode"
        let workers = try (0..<2).map { rank in
            try ClusterWorkerProcess(launch: .init(executable: executable,
                arguments: [String(rank), behavior, actualEpoch.uuidString.lowercased(), logPath(index, rank).path], environment: [:]),
                expectedIdentity: fixtureIdentity(actualEpoch), rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                startupDeadline: now + 5_000_000_000, lifetimeDeadline: lifetime)
        }
        groups.append(workers); epochs.append(actualEpoch); openedAt.append(now)
        do {
            for worker in workers { try worker.launch() }
            let pair = try ClusterWorkerPair(workers: workers, startupDeadline: now + 5_000_000_000)
            var nativeAt: UInt64?
            return CancellationOwnedPair(pair: pair, endpoints: workers, leaseReleaseObserved: { [self] in
                guard workers.allSatisfy(\.nativeCleanupObserved) else { return [false, false] }
                if missingFirstACK && index == 0 { return [true, false] }
                let now = DispatchTime.now().uptimeNanoseconds
                if nativeAt == nil { nativeAt = now }
                let released = !delayedACK || now - nativeAt! >= 120_000_000
                if index == 0 && released && firstACKObservedAt == nil { firstACKObservedAt = now }
                return [released, released] // Explicit CPU stand-in, not authenticated network evidence.
            })
        } catch {
            for worker in workers { worker.requestNativeCleanup() }; for worker in workers { worker.waitForNativeCleanup() }
            throw error
        }
    }
    func logPath(_ index: Int, _ rank: Int) -> URL { directory.appendingPathComponent("pair-\(index)-rank-\(rank).jsonl") }
    func logs(_ index: Int, _ rank: Int) throws -> [[String: Any]] {
        try Data(contentsOf: logPath(index, rank)).split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
    }
    func drain() async {
        for workers in groups { for worker in workers { worker.requestNativeCleanup() } }
        for workers in groups { for worker in workers { await worker.waitUntilNativeCleanup() } }
    }
    func requireReaped() throws { try require(groups.flatMap { $0 }.allSatisfy(\.observedExit), "A real local child remains unreaped") }
}

@MainActor @main struct CancellationCheck {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { exit(64) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[1]), root = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try configuration()
        var actualChildren = 0
        for selected in [CancellationCase.startedBeforeFirstToken, .afterFirstDecode] {
            actualChildren += try await success(selected, executable, root)
        }
        for name in ["missed-phase", "missing-ack", "wrong-recovery", "stale-epoch", "publication"] {
            actualChildren += try await failure(name, executable, root)
        }
        actualChildren += try await alreadyRetired(executable, root)
        try qualificationEmit(["groups": 9, "passed": true, "actualLocalChildren": actualChildren,
            "modelOrNetwork": false, "ownerLeaseACKInFixtureIsSimulated": true])
    }
    static func directory(_ root: URL, _ name: String) throws -> URL {
        let result = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false); return result
    }
    static func configuration() throws {
        _ = try fixtureSettings(); _ = try fixtureSettings(.afterFirstDecode)
        for (key, value) in [("lifetimeSeconds", 301 as Any), ("requestSeconds", 121), ("startupSeconds", 91),
                             ("beforeFirstDelayMilliseconds", true), ("beforeFirstDelayMilliseconds", 0),
                             ("beforeFirstDelayMilliseconds", 1.5), ("beforeFirstDelayMilliseconds", 5001),
                             ("cancellationCase", "afterFinished"), ("promptTokenIDs", [1]), ("expectedTokenIDs", [9]),
                             ("extra", 1)] {
            var object = try fixtureSettingsObject(); object[key] = value
            var refused = false; do { _ = try CancellationSettings.parse(JSONSerialization.data(withJSONObject: object)) } catch { refused = true }
            try require(refused, "Invalid config accepted: \(key)")
        }
        var object = try fixtureSettingsObject(); object["recoveryEpoch"] = object["cancellationEpoch"]
        var refused = false; do { _ = try CancellationSettings.parse(JSONSerialization.data(withJSONObject: object)) } catch { refused = true }
        try require(refused, "Same recovery epoch was accepted")
    }
    static func success(_ selected: CancellationCase, _ executable: URL, _ root: URL) async throws -> Int {
        let factory = FixtureFactory(executable: executable, directory: try directory(root, selected.rawValue))
        factory.delayedACK = true
        let cohort = CancellationCohort(), config = try fixtureSettings(selected)
        do { try await cohort.run(configuration: config, lifetimeDeadline: factory.lifetime, makePair: { try factory.open($0, selected: selected) }) { _ in } }
        catch { await factory.drain(); throw error }
        let a = cohort.records[0], b = cohort.records[1]
        try require(cohort.records.count == 2 && a.completed && b.completed && a.requestID != b.requestID, "Missing completed two-incarnation result")
        try require(a.phaseMatched && a.retiredBeforeCancel == false && a.pairUnavailableAfterCancel && a.finishReason == nil,
            "Cancel did not interrupt selected phase or invalidate Pair")
        try require(a.bytesAfterEarlyRelease == a.reservedBytes && a.reservedBytes == 1600 && a.bytesAfterRelease == 0,
            "Pre-proof charge was released")
        try require(a.cancelCalled! <= a.retirementObserved! && a.retirementObserved! <= a.resourcesReleased!, "Retirement/release order differs")
        try require(factory.firstACKObservedAt != nil && factory.openedAt[1] >= factory.firstACKObservedAt!
            && factory.openedAt[1] >= a.ownerLeaseDrainCompleted!, "Recovery opened before actual cleanup/ACK stand-in")
        try require(factory.epochs == [UUID(uuidString: config.cancellationEpoch)!, UUID(uuidString: config.recoveryEpoch)!], "Fresh epochs differ")
        try require(b.tokenIDs == config.expectedTokenIDs && b.finishReason == "length" && b.bytesAfterRelease == 0, "Recovery sequence differs")
        for rank in 0..<2 {
            let logs = try factory.logs(0, rank)
            let started = logs.first { $0["event"] as? String == "start" }
            let cancelled = logs.first { $0["event"] as? String == "cancel" }
            try require(started != nil && cancelled != nil && cancelled!["active"] as? Bool == true, "Cancel did not reach an active actual child")
            let expected = rank == 0 && selected == .afterFirstDecode ? 2 : 0
            try require(cancelled!["selected"] as? Int == expected, "Actual child cancel phase differs")
            try require(!logs.contains { $0["event"] as? String == "finished" }, "Cancel only occurred after finish")
        }
        try factory.requireReaped(); try qualificationEmit(["case": selected.rawValue, "observations": try cohort.records.map { try $0.object }])
        return factory.groups.count * 2
    }
    static func failure(_ name: String, _ executable: URL, _ root: URL) async throws -> Int {
        let factory = FixtureFactory(executable: executable, directory: try directory(root, name))
        factory.fastFirst = name == "missed-phase"; factory.missingFirstACK = name == "missing-ack"
        factory.badRecovery = name == "wrong-recovery"; factory.staleRecovery = name == "stale-epoch"
        let cohort = CancellationCohort(), config = try fixtureSettings()
        var refused = false
        do {
            try await cohort.run(configuration: config, lifetimeDeadline: factory.lifetime,
                makePair: { try factory.open($0, selected: config.cancellationCase) }) { _ in
                    if name == "publication" { throw QualificationFailure.invalid("Invented sink failure") }
                }
        } catch { refused = true }
        await factory.drain(); try factory.requireReaped()
        try require(refused, "Invalid cancellation/recovery passed: \(name)")
        let expectedGroups = ["wrong-recovery", "stale-epoch"].contains(name) ? 2 : 1
        try require(factory.groups.count == expectedGroups, "Failure opened an unpermitted recovery Pair")
        if name == "missed-phase" { try require(!cohort.records[0].phaseMatched, "Early first token qualified as prefill cancellation") }
        if name == "missing-ack" { try require(cohort.records[0].nativeCleanupObserved == [true, true]
            && cohort.records[0].ownerLeaseReleaseObserved == [true, false], "Missing lease ACK was hidden") }
        if name == "stale-epoch" { try require(cohort.records[1].startCalled == nil, "Stale epoch ran a request") }
        try qualificationEmit(["case": name, "refused": true, "observations": try cohort.records.map { try $0.object }])
        return factory.groups.count * 2
    }
    static func alreadyRetired(_ executable: URL, _ root: URL) async throws -> Int {
        let factory = FixtureFactory(executable: executable, directory: try directory(root, "already-retired")); factory.fastFirst = true
        let epoch = UUID(), owned = try factory.open(epoch, selected: .afterFirstDecode)
        let request = try owned.pair.reserve(requestID: UUID(), reservation: .init(profileID: fixtureProfile.id,
            promptTokenIDs: [Int](repeating: 1, count: 8192), stopTokenIDs: [], outputCount: 128, chunkSize: 512,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 10_000_000_000, capacityLimitBytes: 2048))
        try request.start { _ in true }; await request.waitUntilRetired()
        var record = CancellationObservation(phase: "cancellation", membershipEpoch: epoch.uuidString, requestID: request.requestID.uuidString)
        record.reservedBytes = request.reservedBytes
        let sink = CancellationCapture(record, expected: Array(9..<137), selectedCase: .startedBeforeFirstToken)
        sink.markStart(); sink.cancel(request, pair: owned.pair)
        try require(!sink.snapshot.phaseMatched && sink.snapshot.retiredBeforeCancel == true && sink.snapshot.failure != nil,
                    "No-op cancellation after completed request was accepted")
        _ = await owned.close(lifetimeDeadline: factory.lifetime); try factory.requireReaped()
        return 2
    }
}
