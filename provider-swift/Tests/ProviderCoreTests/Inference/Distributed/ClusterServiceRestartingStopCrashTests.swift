import Foundation
import Testing
@testable import ProviderCore

/// Every step that stops the pair only to start it again (`ClusterRestartingStop.Step`), ended at every point at which
/// its service can end. The pair's stop clears its saved start, and nothing starts a pair whose start is cleared: a
/// step ended between its stop and its start left the pair stopped on both Macs until a person started it. Only the
/// re-plan after an update left a mark for the next run; the memory re-plan, the approval change and the registration
/// left none.
///
/// A cell runs one step through its own entry point, the pair's real stop inside it, and takes the setup record as it
/// is on disk at one point: a service ended there leaves exactly that. A person stops the pair after that, or nobody
/// does. Then the next run of the service starts over the same store. The pair must be started with no stop request
/// left, unless the person stopped it. No cell waits: nothing here runs a service loop.
extension ClusterServiceRestartingStopTests {
    /// Where a step's service can end, in the order a step passes them.
    enum CrashPoint: String, CaseIterable, Sendable {
        case marked = "after its mark"
        case stopRequestSaved = "in its stop"
        case stopped = "after its stop"
        case saved = "after its save"
        case beforeServe = "before its start"
    }

    struct CrashCell: CustomStringConvertible {
        let step: ClusterRestartingStop.Step
        let point: CrashPoint
        let localOnly: Bool
        /// Control moved to the Mac that joined the onboarding: this Mac leads by its recorded claim while its
        /// onboarding role names the other Mac (the steps run on the derived control leader).
        let ledByTheMacThatJoined: Bool
        let stopAsked: Bool

        var description: String {
            [step.rawValue, point.rawValue, localOnly ? "local only" : "through Darkbloom",
             ledByTheMacThatJoined ? "control moved to the Mac that joined" : "control where the onboarding began",
             stopAsked ? "a person stopped the pair since" : "nobody stopped it"].joined(separator: ", ")
        }

        static func all(of step: ClusterRestartingStop.Step) -> [CrashCell] {
            CrashPoint.allCases.flatMap { point in
                [true, false].flatMap { localOnly in
                    [false, true].flatMap { moved in
                        [false, true].map { CrashCell(step: step, point: point, localOnly: localOnly, ledByTheMacThatJoined: moved, stopAsked: $0) }
                    }
                }
            }
        }
    }

    /// The record as it was on disk when the step passed `point`.
    final class Crash: @unchecked Sendable {
        let point: CrashPoint
        private let store: ClusterSetupStore
        private let lock = NSLock()
        private var taken: ClusterSetupRecord?

        init(at point: CrashPoint, store: ClusterSetupStore) { self.point = point; self.store = store }

        func reached(_ passed: CrashPoint) {
            guard passed == point, let record = try? store.readRecord() else { return }
            lock.withLock { if taken == nil { taken = record } }
        }

        var record: ClusterSetupRecord? { lock.withLock { taken } }
    }

    private static let offered = ClusterOnboardingModelChoice(title: ClusterApprovalMacs.model, lines: ["fixture plan"], blocker: nil,
                                                              modelID: ClusterApprovalMacs.model)

    /// A pair whose coordinator serves a model approval for its setup, so a registration has one to save.
    private static func offeredPair() throws -> (ClusterApprovalMacs, CountingCoordinator) {
        let coordinator = try CountingCoordinator()
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:\(coordinator.port)/ws/provider")
        coordinator.approvals = try ClusterApprovalMacs.body([macs.modelApproval()])
        return (macs, coordinator)
    }

    /// The other Mac confirmed this Mac's claim, so the service's steps act. No listener runs: the pairing stays where
    /// the next run reads it.
    private static func confirm(_ service: ClusterService, _ macs: ClusterApprovalMacs) {
        let local = macs.leader.memberID, peer = macs.follower.memberID
        var node = ClusterControlNode(localID: local,
            members: [.init(memberID: local, name: "fixture", memoryBytes: 1, gpuCores: 1),
                      .init(memberID: peer, name: "fixture peer", memoryBytes: 1, gpuCores: 1)],
            claim: .init(term: 2, leaderID: local, members: [local, peer], reason: "fixture"), rankOrder: nil,
            now: ClusterService.monotonicSeconds(), ttl: 3_600)
        _ = node.receiveAnswer(from: peer, sent: node.claim,
            answer: .accepted(.init(memberID: peer, name: "fixture peer", memoryBytes: 1, gpuCores: 1)), now: ClusterService.monotonicSeconds())
        service.lock.withLock { service.control = node }
    }

    /// The recorded claim: `leader` leads the pair.
    private static func claim(_ macs: ClusterApprovalMacs, leader: String) -> ClusterControlRecord {
        let local = macs.leader.memberID, peer = macs.follower.memberID
        return ClusterControlRecord(claim: .init(term: 2, leaderID: leader, members: [local, peer], reason: "fixture"),
            members: [.init(memberID: local, name: "fixture", memoryBytes: 1, gpuCores: 1),
                      .init(memberID: peer, name: "fixture peer", memoryBytes: 1, gpuCores: 1)], rankOrder: nil)
    }

    /// A run of the leader's service over the home as it is, both switches of the re-plan after an update on.
    private static func restarted(_ macs: ClusterApprovalMacs) -> ClusterService {
        let service = nextRun(macs)
        service.resumesInterruptedUpdateReplan = true
        service.updateReplanGuard = true
        confirm(service, macs)
        return service
    }

    /// Runs `step` through its own entry point, as its caller runs it under the command lock, with `crash` told at each
    /// point. Its stop is the pair's real one (`OnboardingLive.localStop`), the other Mac answering at once; its start
    /// stands in for `OnboardingLive.localServe`'s first write. What the step said.
    @discardableResult
    private static func drive(_ step: ClusterRestartingStop.Step, _ service: ClusterService, _ crash: Crash) -> [String] {
        let store = service.store, said = ClusterApprovalRecorder<String>()
        let stop: () -> Result<[String], ClusterOnboardingFailure> = {
            crash.reached(.marked)
            if crash.point == .stopRequestSaved {
                // The stop's own first write, as `localStop` makes it: this Mac's part has not released yet.
                _ = try? store.updateRecord { OnboardingLive.recordStop(&$0, id: UUID(), asked: false) }
                crash.reached(.stopRequestSaved)
            }
            let stopped = Self.stop(service) {}()
            if case .success = stopped { crash.reached(.stopped) }
            return stopped
        }
        let serve: () -> Result<[String], ClusterOnboardingFailure> = {
            crash.reached(.beforeServe)
            _ = try? store.updateRecord { $0.leadership?.serving = true }
            return .success([])
        }
        // The memory re-plan takes the command lock itself; the update check, the approval check and a command hold it
        // around the others.
        let held = step == .memoryReplan ? nil : ClusterControlCommandLock.acquire(seconds: 0, file: commandLock(service))
        defer { held?.release() }
        switch step {
        case .updateReplan:
            _ = service.replanAfterUpdate(model: ClusterApprovalMacs.model, .init(reachMembers: { .success([]) }, stop: stop,
                awaitReleased: {}, planModels: { .success([offered]) }, adopt: { _ in crash.reached(.saved); return .success([]) },
                serve: serve))
        case .memoryReplan:
            // `adopt` stands in for `OnboardingLive.localAdopt` on a serving pair, which stops both parts first.
            service.memoryReplan = .init(reachMembers: { .success([]) }, planModels: { .success([offered]) }, adopt: { _ in
                let stopped = stop()
                if case .success = stopped { crash.reached(.saved) }
                return stopped
            }, serve: serve)
            service.replanForMemory(model: ClusterApprovalMacs.model) { said.append($0) }
        case .approvalChange:
            _ = changeApproval(service, stop: stop, drained: { true }, serve: serve, sendToPeer: { _ in crash.reached(.saved) },
                               say: { said.append($0) })
        case .registration:
            // As this Mac's service runs it for a start on the other Mac's screen (`OnboardingLive.execute`).
            let live = service.controlLive
            live.registration = .init(stop: stop, drained: { true }, save: {
                crash.reached(.saved)
                return .init(changed: true, line: "fixture approval saved", note: nil)
            }, serve: serve)
            switch live.answeringForwarded({ live.localRegister() }) {
            case .success(let lines): lines.forEach(said.append)
            case .failure(let failure): failure.lines.forEach(said.append)
            }
        }
        return said.values
    }

    @Test(arguments: ClusterRestartingStop.Step.allCases)
    func aStepEndedAtAnyPointLeavesThePairStartedUnlessAPersonStoppedIt(_ step: ClusterRestartingStop.Step) throws {
        let (macs, coordinator) = try Self.offeredPair()
        defer { coordinator.close() }
        try withExtendedLifetime(macs) {
            let started = try macs.startedLeaderService(powerAssertionReason: "Cluster restarting stop test " + UUID().uuidString)
            let store = started.store, pristine = try store.readRecord()
            for cell in CrashCell.all(of: step) {
                // The pair as the fixture started it, served the cell's way and led by the cell's Mac.
                _ = try store.updateRecord {
                    $0 = pristine
                    if cell.localOnly { $0.leadership?.scope = Self.localOnly }
                    guard cell.ledByTheMacThatJoined else { return }
                    $0.control = Self.claim(macs, leader: macs.leader.memberID)
                    $0.leadership?.role = ClusterOnboardingRole.member.rawValue
                    $0.leadership?.leaderPin = macs.follower.pin
                }
                let before = try store.readRecord(), crash = Crash(at: cell.point, store: store)
                Self.drive(step, Self.restarted(macs), crash)
                let finished = try store.readRecord()
                guard let ended = crash.record else {
                    // A local-only pair is never registered (`OnboardingLive.localRegister`): nothing stops.
                    #expect(step == .registration && cell.localOnly, "\(cell): the step never passed this point")
                    #expect(finished == before, "\(cell): a step that stops nothing changed the record")
                    continue
                }
                #expect(ended.restartingStopMarks.map(\.step) == [.some(step)], "\(cell): the step's mark there: \(ended.restartingStopMarks)")
                #expect(finished.leadership?.serving == true && finished.stopDrain == nil && finished.restartingStopMarks.isEmpty,
                        "\(cell): the step that ran to its end left \(finished)")
                // The service was ended at the point: its next run finds what was on disk then.
                _ = try store.updateRecord { $0 = ended }
                if cell.stopAsked, case .failure(let failure) = started.controlLive.localStop(seconds: 1, asked: true, stopPeer: {}) {
                    Issue.record("\(cell): the person's stop failed: \(failure.lines)")
                }
                let line = Self.restarted(macs).resumeInterruptedRestart()
                let record = try store.readRecord()
                #expect(record.leadership?.serving == !cell.stopAsked,
                        "\(cell): the pair is \(record.leadership?.serving == true ? "started" : "stopped")")
                #expect(record.stopDrain == nil, "\(cell): a stop request stayed")
                #expect(record.restartingStopMarks.isEmpty, "\(cell): a mark stayed: \(record.restartingStopMarks)")
                #expect((line != nil) == (ended.leadership?.serving == false && !cell.stopAsked), "\(cell): \(line ?? "no line")")
            }
        }
    }

    /// What the next run does with the mark of a step other than the re-plan after an update, ended after its stop:
    /// the conditions the re-plan's mark always had. The clock is given, never waited for.
    @Test(arguments: ["ended in its step", "a mark from long ago", "a mark from after now", "control moved to the other Mac since",
                      "a stop while the pair was down", "a step a later build named"])
    func theNextRunPutsBackOnlyARecentMarkOfAStepThisMacStillLeads(_ arm: String) throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            Self.confirm(service, macs)
            let crash = Crash(at: .stopped, store: service.store)
            Self.drive(.memoryReplan, service, crash)
            var ended = try #require(crash.record)
            try #require(ended.restartingStop != nil && ended.leadership?.serving == false)
            // Whole seconds, so the line's age is exact.
            let began = 1_000_000.0
            ended.restartingStop?.startedAt = began
            if arm == "control moved to the other Mac since" { ended.control = Self.claim(macs, leader: macs.follower.memberID) }
            if arm == "a step a later build named" { ended.restartingStop?.step = "aStepOfALaterBuild" }
            _ = try service.store.updateRecord { $0 = ended }
            if arm == "a stop while the pair was down" { ClusterRestartingStop(store: service.store).forget() }
            let now = arm == "a mark from long ago" ? began + 2 * 3600 : arm == "a mark from after now" ? began - 60 : began + 5
            let line = Self.restarted(macs).resumeInterruptedRestart(now: now)
            let record = try service.store.readRecord()
            let resumed = arm == "ended in its step" || arm == "a step a later build named"
            #expect(record.leadership?.serving == resumed, "\(arm): \(line ?? "no line")")
            #expect(record.restartingStopMarks.isEmpty && record.restartingStop == nil, "\(arm): a mark stayed")
            #expect(line == (!resumed ? nil : arm == "ended in its step"
                ? "the previous run of this Mac's cluster service was ended while it planned the model again for the Macs' "
                    + "memory (5 s ago), after it stopped the pair: the pair's start is put back"
                : "a step that stops the pair only to start it again was ended (5 s ago), after it stopped the pair: the pair's "
                    + "start is put back"), "\(arm)")
        }
    }

    /// This Mac's coordinated update drained and restarts the cluster service next: a step begun now would be ended by
    /// that restart after its stop. No step begins, and a progress no supervisor rewrites any more holds none.
    @Test(arguments: ClusterRestartingStop.Step.allCases)
    func noStepBeginsWhileThisMacsUpdateRestartsTheService(_ step: ClusterRestartingStop.Step) throws {
        let (macs, coordinator) = try Self.offeredPair()
        defer { coordinator.close() }
        try withExtendedLifetime(macs) {
            let started = try macs.startedLeaderService(powerAssertionReason: "Cluster restarting stop test " + UUID().uuidString)
            let store = started.store, before = try store.readRecord()
            let progress = ClusterServiceAgent.updateProgressPath(serviceDirectory: store.paths.directory)
            func write(at writtenAt: Double) {
                ClusterPairUpdate.writeProgress(.init(phase: .drained, target: "9.9.9", running: ProviderCore.version,
                    cycleStartedAt: writtenAt - 30, writtenAt: writtenAt), to: progress)
            }
            write(at: Date().timeIntervalSince1970)
            let held = Crash(at: .marked, store: store)
            let said = Self.drive(step, Self.restarted(macs), held)
            #expect(held.record == nil, "\(step.rawValue) stopped the pair while this Mac's update restarts its service")
            #expect(try store.readRecord() == before, "\(step.rawValue) changed the record")
            if step == .memoryReplan {
                #expect(said == ["this Mac's update to 9.9.9 restarts the cluster service next: planning \(ClusterApprovalMacs.model) "
                                 + "again waits for that restart"])
            }
            // The supervisor that wrote the progress is gone: nothing restarts the service.
            write(at: Date().timeIntervalSince1970 - 2 * ClusterPairUpdate.progressStaleSeconds)
            let ran = Crash(at: .marked, store: store)
            Self.drive(step, Self.restarted(macs), ran)
            #expect(ran.record != nil, "\(step.rawValue) did not run with a progress nobody rewrites")
        }
    }

    /// The registration after a start's test, failing in each of its parts: its screen then says both Macs' parts
    /// start again (`ClusterOnboardingDriver.register`), which they did not when the stop failed, the start cleared.
    @Test(arguments: ["the other Mac did not take the stop", "a part did not stop", "the parts do not start again"])
    func aRegistrationThatFailsLeavesThePairStarted(_ failing: String) throws {
        let (macs, coordinator) = try Self.offeredPair()
        defer { coordinator.close() }
        try withExtendedLifetime(macs) {
            let service = try macs.startedLeaderService(powerAssertionReason: "Cluster restarting stop test " + UUID().uuidString)
            let live = service.controlLive, saved = ClusterApprovalRecorder<Bool>()
            live.registration = .init(stop: {
                switch failing {
                case "the other Mac did not take the stop":
                    return Self.stop(service) { throw ClusterSetupFailure("the other Mac did not answer within 30 s") }()
                case "the parts do not start again":
                    // The stop left its request behind, so the start refuses (`OnboardingLive.localServe`).
                    _ = try? service.store.updateRecord { OnboardingLive.recordStop(&$0, id: UUID(), asked: false) }
                    return .success([])
                default: return Self.stop(service) {}()
                }
            }, drained: { failing != "a part did not stop" }, save: {
                saved.append(true)
                return .init(changed: true, line: "fixture approval saved", note: nil)
            }, serve: { live.localServe() })
            guard case .failure(let failure) = live.localRegister() else { Issue.record("\(failing): the registration did not fail"); return }
            switch failing {
            case "the other Mac did not take the stop":
                #expect(failure.lines.first?.contains("did not answer within 30 s") == true, "\(failure.lines)")
                #expect(failure.lines.last == "The cluster was not registered with the coordinator; the pair stays started.")
                #expect(failure.otherMacUnanswered != nil)
            case "a part did not stop":
                #expect(failure.lines == ["A part did not stop within 5 minutes, so the cluster was not registered with the coordinator."])
            default:
                #expect(failure.lines.first == "fixture approval saved.", "\(failure.lines)")
            }
            #expect(saved.values.isEmpty == (failing != "the parts do not start again"), "\(failing): saves: \(saved.values.count)")
            let record = try service.store.readRecord()
            #expect(record.leadership?.serving == true, "\(failing): the failed registration left the pair stopped")
            #expect(record.stopDrain == nil, "\(failing): the stop's request stayed")
            #expect(record.restartingStopMarks.isEmpty, "\(failing): a mark stayed")
        }
    }

    /// The mark is for the next run of the cluster service, which follows the end of the service. A registration that
    /// this Mac's own `darkbloom cluster` command runs is not in the service: a mark it left when it was killed would
    /// wait for the service's next start, which within the hour would put back a start that something else had
    /// cleared since without counting a stop (`ClusterRestartingStop.run`). It writes none, and its own end puts the
    /// start back.
    @Test func aRegistrationThisMacsOwnCommandRunsWritesNoMark() throws {
        let (macs, coordinator) = try Self.offeredPair()
        defer { coordinator.close() }
        try withExtendedLifetime(macs) {
            let service = try macs.startedLeaderService(powerAssertionReason: "Cluster restarting stop test " + UUID().uuidString)
            let live = service.controlLive, crash = Crash(at: .stopped, store: service.store)
            live.registration = .init(stop: {
                let stopped = Self.stop(service) {}()
                crash.reached(.stopped)
                return stopped
            }, drained: { true }, save: { .init(changed: true, line: "fixture approval saved", note: nil) },
               serve: { .failure(.init("the other Mac's part was not started yet: fixture")) })
            guard case .failure = live.localRegister() else { Issue.record("the registration's start did not fail"); return }
            let stopped = try #require(crash.record)
            #expect(stopped.leadership?.serving == false && stopped.restartingStopMarks.isEmpty, "\(stopped.restartingStopMarks)")
            let record = try service.store.readRecord()
            #expect(record.leadership?.serving == true && record.stopDrain == nil, "its own end did not put the start back")
        }
    }

    /// A step restores only the start it found. A pair nobody started is not started by a step run on it, and a stop a
    /// person asked for while a step runs stands at its end.
    @Test func aStepNeverStartsAPairThatAPersonStopped() throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            let stops = service.restartingStops
            #expect(stops.run(.memoryReplan) { service.controlLive.localStop(seconds: 1, asked: true, stopPeer: {}) } != nil)
            var record = try service.store.readRecord()
            #expect(record.leadership?.serving == false && record.stopsAsked == 1, "the step undid a stop a person asked for")
            #expect(record.restartingStopMarks.isEmpty)
            let stopped = record
            #expect(stops.run(.memoryReplan) { true } == true, "a step on a stopped pair did not run")
            record = try service.store.readRecord()
            #expect(record == stopped, "a step started a pair that was not started")
        }
    }

    /// The marks as an earlier build reads them after a rollback (and as this build reads an earlier build's). The
    /// re-plan after an update keeps `updateReplan` with the two fields it always had; every other step writes
    /// `restartingStop`, which a build from before it does not declare: it resumes nothing for those steps, as it
    /// always did, and reads no step as a re-plan after an update.
    @Test func theMarkOfAnUpdateReplanIsWrittenAsBeforeAndTheOtherStepsApart() throws {
        /// The marks as a build from before `restartingStop` declares them.
        struct EarlierRecord: Codable {
            struct UpdateReplanMark: Codable, Equatable { var stopsAsked: Int; var startedAt: Double }
            var schema: String
            var stopsAsked: Int?
            var updateReplan: UpdateReplanMark?
        }
        func written(_ record: ClusterSetupRecord) throws -> (data: Data, object: [String: Any]) {
            let data = try JSONEncoder().encode(record)
            return (data, try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]))
        }
        var record = ClusterSetupRecord()
        record.stopsAsked = 3
        record.markRestartingStop(.updateReplan, startedAt: 1_000)
        var disk = try written(record)
        #expect(Set((disk.object["updateReplan"] as? [String: Any] ?? [:]).keys) == ["stopsAsked", "startedAt"])
        #expect(disk.object["restartingStop"] == nil)
        #expect(try JSONDecoder().decode(EarlierRecord.self, from: disk.data).updateReplan == .init(stopsAsked: 3, startedAt: 1_000))

        for step in ClusterRestartingStop.Step.allCases where step != .updateReplan {
            record = ClusterSetupRecord()
            record.stopsAsked = 3
            record.markRestartingStop(step, startedAt: 1_000)
            disk = try written(record)
            #expect(disk.object["updateReplan"] == nil, "\(step.rawValue) was written where an earlier build reads a re-plan after an update")
            let earlier = try JSONDecoder().decode(EarlierRecord.self, from: disk.data)
            #expect(earlier.updateReplan == nil && earlier.stopsAsked == 3, "\(step.rawValue): an earlier build reads the record as before")
            let read = try JSONDecoder().decode(ClusterSetupRecord.self, from: disk.data)
            #expect(read.restartingStopMarks == [.init(step: step, stopsAsked: 3, startedAt: 1_000)])
            record.clearRestartingStop(step)
            #expect(record.restartingStopMarks.isEmpty)
        }

        // A record without the new field, as an earlier build wrote it in the middle of its re-plan after an update.
        let older = try JSONDecoder().decode(ClusterSetupRecord.self, from: Data(
            #"{"schema":"darkbloom_cluster_setup_wizard_v1","confirmed":[],"sent":[],"checks":[],"stopsAsked":2,"updateReplan":{"stopsAsked":2,"startedAt":1000}}"#.utf8))
        #expect(older.updateReplan == .init(stopsAsked: 2, startedAt: 1_000) && older.restartingStop == nil)
        #expect(older.restartingStopMarks == [.init(step: .updateReplan, stopsAsked: 2, startedAt: 1_000)])
        // A record with it, the step one this build names and one only a later build does: both decode.
        let named: [(String, ClusterRestartingStop.Step?)] = [("approvalChange", .approvalChange), ("aStepOfALaterBuild", nil)]
        for (name, step) in named {
            let newer = try JSONDecoder().decode(ClusterSetupRecord.self, from: Data(
                (#"{"schema":"darkbloom_cluster_setup_wizard_v1","confirmed":[],"sent":[],"checks":[],"#
                    + #""restartingStop":{"step":""# + name + #"","stopsAsked":1,"startedAt":2000}}"#).utf8))
            #expect(newer.updateReplan == nil && newer.restartingStop == .init(step: name, stopsAsked: 1, startedAt: 2_000))
            #expect(newer.restartingStopMarks == [.init(step: step, stopsAsked: 1, startedAt: 2_000)])
        }
    }

    /// Every stop of the pair that no person asked for is a step's stop inside its restarting stop, or the model
    /// change's, whose start is the person's own next command. A stop added anywhere else would clear the pair's saved
    /// start with nothing owing it one: this count names where the unasked stops are.
    @Test func everyUnaskedStopOfThePairIsAStepOfARestartingStop() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var found: [String: Int] = [:]
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            func count(_ call: String) -> Int { text.components(separatedBy: call).count - 1 }
            // Every call of the pair's stop, with or without arguments, but its declarations and a person's stop.
            let unasked = count("localStop(") - count("func localStop(") - count("localStop(asked: true)")
            if unasked > 0 { found[file.lastPathComponent] = unasked }
        }
        // `ClusterService.swift`: the stops of the re-plan after an update and of the approval change, each given to
        // its restarting stop (`replanAfterUpdate`, `changeApproval`). `ClusterOnboardingLive.swift`: the
        // registration's, given to its own; `localAdopt`'s, which the memory re-plan runs inside its restarting
        // stop and a person's model change runs before their own start; and `localStop(asked:)` handing its
        // caller's `asked` on to `localStop(seconds:asked:stopPeer:)`.
        #expect(found == ["ClusterService.swift": 2, "ClusterOnboardingLive.swift": 3],
                "an unasked stop of the pair was added or moved: run it inside `ClusterRestartingStop.run` and name it here")
    }
}
