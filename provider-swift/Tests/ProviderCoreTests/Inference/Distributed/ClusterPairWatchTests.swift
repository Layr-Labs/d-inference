import Foundation
import Testing

@testable import ProviderCore

/// A Mac that stopped clustering serves normally (0.10.8: "online, no traffic"). Whether the pair runs on a Mac comes
/// from what runs (`ClusterPairWatch`), not from its saved start, which stays on when the other Mac stops taking part.
@Suite("Whether the pair actually runs on this Mac")
struct ClusterPairWatchTests {
    private let minute = 60.0

    @Test("a start whose other Mac never answers is given up after 15 minutes, and the part stops")
    func staleStartIsGivenUp() {
        var watch = ClusterPairWatch()
        #expect(watch.tick(now: 1_000, intent: true, otherAnsweredAt: nil, serving: false) == .running)
        #expect(watch.tick(now: 1_000 + 14 * minute, intent: true, otherAnsweredAt: nil, serving: false) == .running)
        let verdict = watch.tick(now: 1_000 + 15 * minute, intent: true, otherAnsweredAt: nil, serving: false)
        #expect(verdict == .otherMacSilent(seconds: 15 * minute))
        #expect(verdict.givesUpPart && !verdict.running)
        #expect(ClusterPairWatch.line(verdict, otherMac: "Apple M5 Max, 128 GB", cli: "darkbloom")
            == "The other Mac (Apple M5 Max, 128 GB) hasn't answered for 15 min; this Mac's part stopped. Run "
                + "`darkbloom start --solo` to serve this Mac alone, or `darkbloom start` to start the pair again.")
    }

    @Test("time asleep doesn't count: waking after a long sleep keeps the part, and gives up 15 awake minutes later")
    func sleepDoesNotCount() {
        var watch = ClusterPairWatch()
        // `raw` counts sleep (the lease clock); `awake` pauses during system sleep.
        var raw = 50_000.0, awake = 2_000.0
        let answered = raw
        #expect(watch.tick(raw: raw, awake: awake, intent: true, otherAnsweredAt: answered, serving: true) == .running)
        raw += 60; awake += 60
        #expect(watch.tick(raw: raw, awake: awake, intent: true, otherAnsweredAt: answered, serving: true) == .running)
        // Two hours asleep: the first tick on waking, before the other Mac's next answer, keeps the part.
        raw += 2 * 3_600; awake += 1
        #expect(watch.tick(raw: raw, awake: awake, intent: true, otherAnsweredAt: answered, serving: false) == .running)
        // The other Mac answers again: running.
        raw += 5; awake += 5
        #expect(watch.tick(raw: raw, awake: awake, intent: true, otherAnsweredAt: raw, serving: true) == .running)
        // It stays gone: given up 15 awake minutes after its last answer, not before.
        let last = raw
        raw += 14 * minute; awake += 14 * minute
        #expect(watch.tick(raw: raw, awake: awake, intent: true, otherAnsweredAt: last, serving: false) == .running)
        raw += minute; awake += minute
        #expect(watch.tick(raw: raw, awake: awake, intent: true, otherAnsweredAt: last, serving: false).givesUpPart)
    }

    @Test("a start's 15-minute window doesn't count sleep either")
    func startWindowSkipsSleep() {
        var watch = ClusterPairWatch()
        var raw = 1_000.0, awake = 1_000.0
        #expect(watch.tick(raw: raw, awake: awake, intent: true, otherAnsweredAt: nil, serving: false) == .running)
        raw += 3 * 3_600 + 10 * minute; awake += 10 * minute
        #expect(watch.tick(raw: raw, awake: awake, intent: true, otherAnsweredAt: nil, serving: false) == .running)
        raw += 5 * minute; awake += 5 * minute
        #expect(watch.tick(raw: raw, awake: awake, intent: true, otherAnsweredAt: nil, serving: false).givesUpPart)
    }

    @Test("a pair whose other Mac reboots for a few minutes keeps running, and forms again")
    func rebootDoesNotBreakThePair() {
        var watch = ClusterPairWatch()
        var now = 5_000.0
        #expect(watch.tick(now: now, intent: true, otherAnsweredAt: now, serving: true) == .running)
        now += 30 * minute
        #expect(watch.tick(now: now, intent: true, otherAnsweredAt: now, serving: true) == .running)
        let lastAnswer = now
        // The other Mac reboots: 6 minutes without an answer, nothing serving.
        for step in 1...6 {
            #expect(watch.tick(now: now + Double(step) * minute, intent: true, otherAnsweredAt: lastAnswer, serving: false) == .running)
        }
        now += 7 * minute
        #expect(watch.tick(now: now, intent: true, otherAnsweredAt: now, serving: false) == .running)
        #expect(watch.tick(now: now + 3 * minute, intent: true, otherAnsweredAt: now + 3 * minute, serving: true) == .running)
    }

    @Test("a given-up part starts again by itself once the other Mac answers")
    func givenUpPartComesBack() {
        var watch = ClusterPairWatch()
        _ = watch.tick(now: 0, intent: true, otherAnsweredAt: 0, serving: true)
        #expect(watch.tick(now: 16 * minute, intent: true, otherAnsweredAt: 0, serving: false).givesUpPart)
        #expect(watch.tick(now: 40 * minute, intent: true, otherAnsweredAt: 40 * minute, serving: false) == .running)
    }

    @Test("both Macs answer but the pair never served in 15 minutes: not running, and the part is left to the person")
    func neverFormed() {
        var watch = ClusterPairWatch()
        _ = watch.tick(now: 0, intent: true, otherAnsweredAt: 0, serving: false)
        #expect(watch.tick(now: 14 * minute, intent: true, otherAnsweredAt: 14 * minute, serving: false) == .running)
        let verdict = watch.tick(now: 15 * minute, intent: true, otherAnsweredAt: 15 * minute, serving: false)
        #expect(verdict == .notServing(seconds: 15 * minute))
        #expect(!verdict.running && !verdict.givesUpPart)
        #expect(ClusterPairWatch.line(verdict, otherMac: nil, cli: "darkbloom-dev")?.hasSuffix("Run `darkbloom-dev start --solo` to "
            + "serve this Mac alone, or `darkbloom-dev start` to start the pair again.") == true)
    }

    @Test("a pair that served once is never 'not serving' through an outage while the other Mac answers")
    func servedOnce() {
        var watch = ClusterPairWatch()
        _ = watch.tick(now: 0, intent: true, otherAnsweredAt: 0, serving: true)
        #expect(watch.tick(now: 60 * minute, intent: true, otherAnsweredAt: 60 * minute, serving: false) == .running)
    }

    @Test("a stop clears the watch: the next start gets the whole window again")
    func stopResets() {
        var watch = ClusterPairWatch()
        _ = watch.tick(now: 0, intent: true, otherAnsweredAt: nil, serving: false)
        #expect(watch.tick(now: 20 * minute, intent: true, otherAnsweredAt: nil, serving: false).givesUpPart)
        #expect(watch.tick(now: 21 * minute, intent: false, otherAnsweredAt: nil, serving: false) == .stopped)
        #expect(watch.tick(now: 22 * minute, intent: true, otherAnsweredAt: nil, serving: false) == .running)
        #expect(ClusterPairWatch.line(.running, otherMac: nil, cli: "darkbloom") == nil)
        #expect(ClusterPairWatch.line(.stopped, otherMac: nil, cli: "darkbloom") == nil)
    }

    @Test("the control node records only real answers from the other Mac")
    func otherAnsweredAtIsOnlyARealAnswer() {
        let a = ClusterControlMember(memberID: "a", name: "A", memoryBytes: 1, gpuCores: 1)
        let b = ClusterControlMember(memberID: "b", name: "B", memoryBytes: 1, gpuCores: 1)
        var node = ClusterControlNode(localID: "a", members: [a, b], claim: nil, rankOrder: ["a", "b"], now: 0, ttl: 30)
        #expect(node.otherAnsweredAt == nil)
        _ = node.receiveAnswer(from: "b", sent: node.claim, answer: .accepted(b), now: 12)
        #expect(node.otherAnsweredAt == 12)
    }

    @Test("a given-up pair runs no part, which frees the serving lock; a pair that runs keeps its part")
    func givenUpPartStops() {
        let silent = ClusterPairWatch.Verdict.otherMacSilent(seconds: 900)
        #expect(ClusterPairWatch.part(.cluster, verdict: silent, localOnly: false, singleMacJob: false) == .none)
        #expect(ClusterPairWatch.part(.keep, verdict: silent, localOnly: false, singleMacJob: false) == .none)
        #expect(ClusterPairWatch.part(.solo("m"), verdict: silent, localOnly: false, singleMacJob: true) == .none)
        #expect(ClusterPairWatch.part(.solo("m"), verdict: silent, localOnly: false, singleMacJob: false) == .solo("m"))
        #expect(ClusterPairWatch.part(.solo("m"), verdict: silent, localOnly: true, singleMacJob: true) == .solo("m"))
        for verdict in [ClusterPairWatch.Verdict.running, .notServing(seconds: 900), .stopped] {
            #expect(ClusterPairWatch.part(.cluster, verdict: verdict, localOnly: false, singleMacJob: true) == .cluster)
        }
    }

    @Test("0.10.8's updater installs 0.10.9 on a Mac with a stale part: single-Mac serving comes back once the 0.10.9 service gives the part up")
    func updateFrom0108OnAStaleMac() {
        // 1. Right after the install, the 0.10.8 cluster service still runs (no verdict). Its other Mac is gone, so its
        //    control waits or can't serve: the pair isn't running here, and the watchdog and `start` act on that.
        for mode in ["waiting", "cannotServe"] {
            #expect(!ClusterService.pairRuns(status(serving: true, pairRunning: nil, mode: mode)))
        }
        // 2. At the next login the 0.10.9 service runs. Its part may run while the other Mac might still answer…
        var watch = ClusterPairWatch()
        let login = 10_000.0
        var verdict = watch.tick(now: login, intent: true, otherAnsweredAt: nil, serving: false)
        #expect(verdict == .running)
        #expect(ClusterService.pairRuns(status(serving: true, pairRunning: verdict.running)), "a pair starting at login is protected")
        // 3. …and gives it up after 15 minutes without an answer: the lock is free, the status says why.
        verdict = watch.tick(now: login + ClusterPairWatch.giveUpSeconds, intent: true, otherAnsweredAt: nil, serving: false)
        #expect(ClusterPairWatch.part(.cluster, verdict: verdict, localOnly: false, singleMacJob: true) == .none)
        #expect(!ClusterService.pairRuns(status(serving: true, pairRunning: verdict.running)))
    }

    // MARK: - What `update`, the watchdog and `start` read

    private func status(serving: Bool, pairRunning: Bool?, mode: String? = nil) -> ClusterServiceStatus {
        var status = ClusterServiceStatus(role: "leader", serving: serving, modelName: "m", sessionLeader: true, localRank: 0,
                                          setup: nil, child: .init(running: true, starts: 1), session: nil)
        status.pairRunning = pairRunning
        status.control = mode.map { .init(leaderID: "a", leaderName: "A", term: 1, reason: "", leads: true, line: "", mode: $0) }
        return status
    }

    @Test("the pair runs here by the service's verdict, not by its saved start")
    func pairRunsByVerdict() {
        #expect(!ClusterService.pairRuns(nil))
        #expect(!ClusterService.pairRuns(status(serving: false, pairRunning: nil)))
        #expect(ClusterService.pairRuns(status(serving: true, pairRunning: true)))
        // The 0.10.8 case: started, but the pair doesn't run here.
        #expect(!ClusterService.pairRuns(status(serving: true, pairRunning: false)))
    }

    @Test("update and the watchdog leave the lock to a pair whose other Mac answers, even before it has served (a long first load)")
    func pairKeepsLockWhileTheOtherMacAnswers() {
        // Both Macs answer, the pair hasn't served in 15 minutes (a first load, the coordinator away): not "running" for
        // the person's choice, but no automatic single-Mac serving takes the lock.
        #expect(ClusterService.pairKeepsLock(status(serving: true, pairRunning: false, mode: "cluster")))
        #expect(ClusterService.pairKeepsLock(status(serving: true, pairRunning: true)))
        // The other Mac is gone (given up), or the pair is stopped: single-Mac serving comes back.
        for mode in ["waiting", "alone", "idle", "cannotServe"] {
            #expect(!ClusterService.pairKeepsLock(status(serving: true, pairRunning: false, mode: mode)))
        }
        #expect(!ClusterService.pairKeepsLock(status(serving: true, pairRunning: false)))
        #expect(!ClusterService.pairKeepsLock(status(serving: false, pairRunning: nil, mode: "cluster")))
        #expect(!ClusterService.pairKeepsLock(nil))
    }

    @Test("a 0.10.8 service still running after the update to 0.10.9: its control mode decides")
    func olderServiceStatus() throws {
        // 0.10.8's status has no verdict: decoded from its own JSON, the field is absent.
        var old = status(serving: true, pairRunning: nil, mode: "cannotServe")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "pairRunning")
        old = try JSONDecoder().decode(ClusterServiceStatus.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.pairRunning == nil)
        #expect(!ClusterService.pairRuns(old))
        for mode in ["waiting", "alone", "idle"] { #expect(!ClusterService.pairRuns(status(serving: true, pairRunning: nil, mode: mode))) }
        for mode in ["cluster", "following", "confirming"] { #expect(ClusterService.pairRuns(status(serving: true, pairRunning: nil, mode: mode))) }
        #expect(ClusterService.pairRuns(status(serving: true, pairRunning: nil)))
    }

    // MARK: - Registration after the way back

    @Test("single-Mac serving after the way back registers as an ordinary provider: role solo, every model, no cluster fields")
    func registrationAfterTheWayBack() throws {
        let hardware = HardwareInfo(machineModel: "fixture", chipName: "Apple M4", chipFamily: .m4, chipTier: .pro, memoryGb: 24,
                                    memoryAvailableGb: 20, cpuCores: .init(total: 12, performance: 8, efficiency: 4), gpuCores: 16,
                                    memoryBandwidthGbs: 200)
        let models = ["acme/Alpha-4bit", "acme/Beta-4bit"].map {
            ModelInfo(id: $0, modelType: "qwen3", sizeBytes: 1, estimatedMemoryGb: 1, weightHash: "hash-\($0)")
        }
        // Even a leftover membership in the configuration never reaches a solo registration.
        let leftover = try ClusterMembership(clusterID: "pair-a", rank: 0, policySHA256: String(repeating: "ab", count: 32))
        for membership in [nil, leftover] {
            let config = CoordinatorClientConfig(url: "wss://coordinator.invalid/ws", hardware: hardware, models: models,
                                                 backendName: "mlx-swift", attestation: nil, executionRole: .solo,
                                                 clusterMembership: membership)
            let data = try CoordinatorClientCodec.encodeRegistration(from: config)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["execution_role"] == nil)
            #expect(json["cluster_membership"] == nil)
            #expect(json["cluster_models"] == nil)
            #expect(json["member_registration_nonce"] == nil)
            let ids = (json["models"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
            #expect(ids == ["acme/Alpha-4bit", "acme/Beta-4bit"])
        }
    }
}
