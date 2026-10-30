import Darwin
import Foundation
import IOKit.pwr_mgt
import Testing
import DarkbloomClusterProcess
@testable import ProviderCore

/// Runs the actual service loop, process launch/stop, status publication, and
/// IOKit ownership. Only the path namespace and initial recovery deadline vary.
@Suite(.serialized)
struct ClusterServiceRecoveryTests {
    @Test func leftoverRecoveryAndPowerOwnershipSurviveTwoServiceLifetimes() throws {
        let home = try NativePairMemberFixture.privateRoot()
        let helper = home.appendingPathComponent("service-part-fixture")
        try NativePairMemberFixture.helper().write(to: helper, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let paths = try ClusterUserPaths(homeDirectory: home)
        let store = ClusterSetupStore(paths: .init(paths: paths))
        let statusFile = store.paths.directory.appendingPathComponent("service-status.json")
        let lockFile = store.paths.directory.appendingPathComponent("service.lock")
        let pidFile = store.paths.directory.appendingPathComponent("service.pid")
        var completed = false
        defer {
            // On failed cleanup retain the private directory for diagnosis.
            if completed { try? FileManager.default.removeItem(at: home) }
        }
        try #require(try serviceAssertionTypes().isEmpty, "this test must start without another service's assertions")

        for lifetime in 0..<2 {
            let directory = home.appendingPathComponent("lifetime-\(lifetime)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let leftover = Process()
            leftover.executableURL = helper
            leftover.arguments = ["--service-part-fixture", directory.path, "leftover"]
            leftover.standardInput = FileHandle.nullDevice
            leftover.standardOutput = FileHandle.nullDevice
            leftover.standardError = FileHandle.nullDevice
            try leftover.run()
            var run: ServiceRecoveryRun?
            defer {
                // Never signal a foreign/recycled PID. Service-owned replacements
                // are stopped by the actual service; the Process here is ours.
                try? Data().write(to: directory.appendingPathComponent("release-leftover"))
                try? Data().write(to: directory.appendingPathComponent("release-replacement"))
                run?.requestStop()
                if let run { #expect(run.join(seconds: 10), "service cleanup must join; retain \(home.path) on failure") }
                if leftover.isRunning { leftover.terminate() }
                let ended = waitForRecovery(seconds: 5) { !leftover.isRunning }
                #expect(ended, "owned leftover did not exit")
                if ended { leftover.waitUntilExit() }
            }
            let oldPID = leftover.processIdentifier
            try #require(waitForRecovery { readyPIDs(in: directory, role: "leftover") == [oldPID] })
            let oldStart = try #require(ClusterProcessTable.startTime(of: oldPID))
            let oldPart = ClusterService.RecordedPart(pid: oldPID, startedAt: oldStart, solo: true)

            var leadership = ClusterOnboardingLeadership(role: "leader", leaderPin: "fixture-local",
                peerPin: "fixture-peer", peerName: "fixture peer", since: "fixture")
            leadership.serving = true
            leadership.modelName = "fixture-model"
            _ = try store.updateRecord { $0.leadership = leadership }
            // The status is from a previous service, but the part is a real,
            // currently alive process whose start time comes from the kernel.
            let previous = ClusterServiceStatus(role: "leader", serving: true, modelName: "fixture-model",
                sessionLeader: false, localRank: nil, setup: nil,
                child: .init(running: true, starts: 1, lastEnd: nil, restartInSeconds: nil, lastError: nil,
                             pid: oldPID, startedAt: oldStart, solo: true),
                session: nil, control: nil, servicePID: -1)
            try JSONEncoder().encode(previous).write(to: statusFile, options: .atomic)

            let wizard = ClusterSetupOperations.LiveSettings(providerConfiguration: home.appendingPathComponent("provider.toml"),
                darkbloomExecutable: helper, sessionArguments: [], pair: nil, dryRun: true, version: "fixture")
            let service = ClusterService(settings: .init(wizard: wizard, leaderArguments: [], followerArguments: [],
                soloArguments: ["--service-part-fixture", directory.path, "replacement"]),
                paths: paths, recoveryGraceSeconds: 0.2, supervisionIntervalSeconds: serviceSupervisionInterval)
            // Existing collaborator: a real control node already past its peer
            // absence grace. No fake launch/supervise/power/publication methods.
            let local = "mac-aaaaaaaaaaaa", peer = "mac-bbbbbbbbbbbb"
            let now = ClusterService.monotonicSeconds()
            let node = ClusterControlNode(localID: local,
                members: [.init(memberID: local, name: "fixture", memoryBytes: 1, gpuCores: 1, holdsModelAlone: true)],
                claim: .init(term: 1, leaderID: local, members: [local, peer], reason: "fixture"),
                rankOrder: [local, peer], now: now - 2, ttl: 1, soloGrace: 0)
            try #require(node.mode(now: now) == .alone(missing: [peer]))
            service.lock.withLock { service.control = node }
            let currentRun = ServiceRecoveryRun(service: service)
            run = currentRun
            currentRun.start()

            try #require(waitForRecovery {
                guard let value = readRecoveryStatus(statusFile) else { return false }
                return value.servicePID == getpid() && value.child.pid == oldPID && value.child.notice != nil
            }, "the real loop must publish the adopted leftover after its cleanup deadline")
            try #require(FileManager.default.fileExists(atPath: directory.appendingPathComponent("leftover-\(oldPID).term").path),
                         "startup cleanup must actually send TERM")
            let held = try serviceAssertionTypes()
            try #require(held.contains(kIOPMAssertionTypeNoIdleSleep) && held.contains("NetworkClientActive"))
            #expect(Set(held).count == held.count, "at most one assertion of each type")
            var publication = try recoveryPublicationDate(statusFile)
            for _ in 0..<2 {
                publication = try nextRecoveryPublication(statusFile, after: publication)
                let value = try #require(readRecoveryStatus(statusFile))
                #expect(value.child.pid == oldPID && value.child.startedAt == oldStart && value.child.running)
                #expect(value.child.starts == 0 && value.child.restartInSeconds == nil)
                #expect(value.control?.mode == "alone" && value.serving, "a replacement is otherwise wanted")
                #expect(readyPIDs(in: directory, role: "replacement").isEmpty)
                #expect(ClusterService.runningPart(oldPart) != nil)
                #expect(try serviceAssertionTypes() == held)
            }

            // Saved intent alone must not mask a broken leftover-to-power edge.
            _ = try store.updateRecord { $0.leadership?.serving = false }
            try #require(waitForRecovery { readRecoveryStatus(statusFile)?.serving == false })
            publication = try nextRecoveryPublication(statusFile, after: recoveryPublicationDate(statusFile))
            #expect(readRecoveryStatus(statusFile)?.child.pid == oldPID)
            #expect(try serviceAssertionTypes() == held)
            _ = try store.updateRecord { $0.leadership?.serving = true }
            try #require(waitForRecovery { readRecoveryStatus(statusFile)?.serving == true })

            try Data().write(to: directory.appendingPathComponent("release-leftover"))
            try #require(waitForRecovery { !leftover.isRunning && ClusterService.runningPart(oldPart) == nil })
            leftover.waitUntilExit()
            try #require(waitForRecovery {
                guard let value = readRecoveryStatus(statusFile) else { return false }
                return value.child.running && value.child.starts == 1 && value.child.pid != oldPID
                    && readyPIDs(in: directory, role: "replacement").count == 1
            }, "one replacement must start after the old process is observed gone")
            let replacement = try #require(ClusterService.recordedPart(readRecoveryStatus(statusFile)))
            #expect(readyPIDs(in: directory, role: "replacement") == [replacement.pid])
            publication = try recoveryPublicationDate(statusFile)
            for _ in 0..<2 {
                publication = try nextRecoveryPublication(statusFile, after: publication)
                #expect(readRecoveryStatus(statusFile)?.child.starts == 1)
                #expect(readRecoveryStatus(statusFile)?.child.pid == replacement.pid)
                #expect(readyPIDs(in: directory, role: "replacement") == [replacement.pid])
                #expect(try serviceAssertionTypes() == held)
            }

            if lifetime == 0 {
                _ = try store.updateRecord { $0.leadership?.serving = false }
            } else {
                // A second service instance on the same files exercises lock
                // reacquisition and exit while saved serving remains true.
                currentRun.requestStop()
            }
            let requested = directory.appendingPathComponent("replacement-\(replacement.pid).term")
            try #require(waitForRecovery { FileManager.default.fileExists(atPath: requested.path) })
            #expect(ClusterService.runningPart(replacement) != nil)
            #expect(try serviceAssertionTypes() == held, "retirement is requested but has not finished")
            try Data().write(to: directory.appendingPathComponent("release-replacement"))
            try #require(waitForRecovery { ClusterService.runningPart(replacement) == nil })
            if lifetime == 0 {
                try #require(waitForRecovery { readRecoveryStatus(statusFile)?.child.running == false })
                #expect(try serviceAssertionTypes().isEmpty, "idle service releases after its child stops")
                currentRun.requestStop()
            }
            try #require(currentRun.join(seconds: 10), "service did not return: \(currentRun.log)")
            #expect(try currentRun.result(), "run must report clean retirement")
            let final = try #require(readRecoveryStatus(statusFile))
            #expect(!final.child.running && final.child.pid == nil && final.child.starts == 1)
            #expect(!FileManager.default.fileExists(atPath: pidFile.path))
            #expect(try serviceAssertionTypes().isEmpty, "run's defer releases even with saved serving true")
            let fd = open(lockFile.path, O_RDONLY | O_CLOEXEC)
            try #require(fd >= 0)
            let acquired = flock(fd, LOCK_EX | LOCK_NB) == 0
            if acquired { _ = flock(fd, LOCK_UN) }
            close(fd)
            #expect(acquired, "the next service lifetime must be able to take the lock")
        }
        completed = true
    }
    @Test func plannedStopWaitsForOwnedServiceChildBeforePeerAndRetainsFailureIntent() throws {
        for outcome in ["success", "missing-peer", "timeout"] {
            let home = try NativePairMemberFixture.privateRoot()
            let helper = home.appendingPathComponent("service-part-fixture")
            try NativePairMemberFixture.helper().write(to: helper, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            let directory = home.appendingPathComponent("part", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let paths = try ClusterUserPaths(homeDirectory: home)
            let wizard = ClusterSetupOperations.LiveSettings(providerConfiguration: home.appendingPathComponent("provider.toml"),
                darkbloomExecutable: helper, sessionArguments: [], pair: nil, dryRun: true, version: "fixture")
            let service = ClusterService(settings: .init(wizard: wizard, leaderArguments: [], followerArguments: [],
                soloArguments: ["--service-part-fixture", directory.path, "replacement"]), paths: paths,
                supervisionIntervalSeconds: serviceSupervisionInterval)
            var leadership = ClusterOnboardingLeadership(role: "leader", leaderPin: "fixture-local",
                peerPin: "fixture-peer", peerName: "fixture peer", since: "fixture")
            leadership.serving = true; leadership.modelName = "fixture-model"
            _ = try service.store.updateRecord { $0.leadership = leadership }
            let local = "mac-aaaaaaaaaaaa", peer = "mac-bbbbbbbbbbbb"
            let now = ClusterService.monotonicSeconds()
            let node = ClusterControlNode(localID: local,
                members: [.init(memberID: local, name: "fixture", memoryBytes: 1, gpuCores: 1, holdsModelAlone: true)],
                claim: .init(term: 1, leaderID: local, members: [local, peer], reason: "fixture"),
                rankOrder: [local, peer], now: now - 2, ttl: 1, soloGrace: 0)
            service.lock.withLock { service.control = node }
            let live = service.controlLive
            let run = ServiceRecoveryRun(service: service)
            let stopped = ServiceStopRun()
            let statusFile = service.store.paths.directory.appendingPathComponent("service-status.json")
            var completed = false
            defer {
                try? Data().write(to: directory.appendingPathComponent("release-replacement"))
                service.lock.withLock { service.leaseInFlight = false }
                run.requestStop()
                #expect(stopped.join(seconds: 12))
                #expect(run.join(seconds: 12), "owned service must finish; retain \(home.path) on failure")
                if completed { try? FileManager.default.removeItem(at: home) }
            }
            run.start()
            try #require(waitForRecovery { ClusterService.recordedPart(readRecoveryStatus(statusFile)) != nil })
            let part = try #require(ClusterService.recordedPart(readRecoveryStatus(statusFile)))
            try #require(waitForRecovery { readyPIDs(in: directory, role: "replacement") == [part.pid] })
            stopped.start(live: live, part: part, seconds: outcome == "timeout" ? 0.2 : 10,
                          missingPeer: outcome == "missing-peer")
            let requested = directory.appendingPathComponent("replacement-\(part.pid).term")
            try #require(waitForRecovery { FileManager.default.fileExists(atPath: requested.path) })
            #expect(ClusterService.runningPart(part) != nil, "TERM is not a retirement acknowledgement")
            #expect(stopped.peerCalls == 0, "the peer cannot stop while this owned child is still alive")
            let draining = try service.store.readRecord()
            #expect(draining.leadership?.serving == false && draining.stopDrain?.keepPeerRunning == true)
            requireFollowerLease(record: draining, running: true)
            if case .success = live.localServe() { Issue.record("a pending stop must refuse a fresh start") }
            if outcome == "timeout" {
                try #require(stopped.join(seconds: 3), "the local retirement wait is bounded")
                #expect(!stopped.succeeded && stopped.peerCalls == 0)
                #expect(ClusterService.runningPart(part) != nil, "a timeout neither kills nor claims release")
            }
            // Hold the actual outbound-lease custody flag after the local
            // child retires. A final stale running=true lease must settle too.
            if outcome == "success" { service.lock.withLock { service.leaseInFlight = true } }
            try Data().write(to: directory.appendingPathComponent("release-replacement"))
            try #require(waitForRecovery { ClusterService.runningPart(part) == nil })
            if outcome == "success" {
                #expect(!stopped.join(seconds: 0.3) && stopped.peerCalls == 0)
                #expect(try service.store.readRecord().stopDrain != nil)
                service.lock.withLock { service.leaseInFlight = false }
            }
            try #require(waitForRecovery { readRecoveryStatus(statusFile)?.child.running == false })
            try #require(stopped.join(seconds: 12))
            if outcome == "timeout" {
                let retry = ServiceStopRun()
                retry.start(live: live, part: part, seconds: 3, missingPeer: false)
                try #require(retry.join(seconds: 5))
                #expect(retry.succeeded && retry.peerCalls == 1 && !retry.liveAtPeer)
            } else {
                #expect(stopped.peerCalls == 1 && !stopped.liveAtPeer)
                #expect(stopped.succeeded == (outcome == "success"))
            }
            let retired = try service.store.readRecord()
            #expect(retired.stopDrain == nil)
            requireFollowerLease(record: retired, running: false)
            #expect(retired.leadership?.serving == false,
                    "missing peer and local timeout preserve stopped intent for later reconciliation")
            run.requestStop()
            try #require(run.join(seconds: 10))
            #expect(try run.result())
            completed = true
        }
    }

    @Test func plannedStopRejectsStaleIdleWhileActualServiceStartsItsChild() throws {
        let home = try NativePairMemberFixture.privateRoot()
        let helper = home.appendingPathComponent("service-part-fixture")
        try NativePairMemberFixture.helper().write(to: helper, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let directory = home.appendingPathComponent("part", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let paths = try ClusterUserPaths(homeDirectory: home)
        let wizard = ClusterSetupOperations.LiveSettings(providerConfiguration: home.appendingPathComponent("provider.toml"),
            darkbloomExecutable: helper, sessionArguments: [], pair: nil, dryRun: true, version: "fixture")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let service = ClusterService(settings: .init(wizard: wizard, leaderArguments: [], followerArguments: [],
            soloArguments: ["--service-part-fixture", directory.path, "replacement"]), paths: paths,
            beforePartStart: { entered.signal(); release.wait() })
        var leadership = ClusterOnboardingLeadership(role: "leader", leaderPin: "fixture-local",
            peerPin: "fixture-peer", peerName: "fixture peer", since: "fixture")
        leadership.serving = false; leadership.modelName = "fixture-model"
        _ = try service.store.updateRecord { $0.leadership = leadership }
        let local = "mac-aaaaaaaaaaaa", peer = "mac-bbbbbbbbbbbb"
        let node = ClusterControlNode(localID: local,
            members: [.init(memberID: local, name: "fixture", memoryBytes: 1, gpuCores: 1, holdsModelAlone: true)],
            claim: .init(term: 1, leaderID: local, members: [local, peer], reason: "fixture"),
            rankOrder: [local, peer], now: ClusterService.monotonicSeconds() - 2, ttl: 1, soloGrace: 0)
        service.lock.withLock { service.control = node }
        let live = service.controlLive
        let run = ServiceRecoveryRun(service: service), stopped = ServiceStopRun()
        let statusFile = service.store.paths.directory.appendingPathComponent("service-status.json")
        let acknowledgement = service.store.paths.directory.appendingPathComponent("service-supervision.json")
        var completed = false
        defer {
            release.signal()
            try? Data().write(to: directory.appendingPathComponent("release-replacement"))
            run.requestStop()
            #expect(stopped.join(seconds: 12))
            #expect(run.join(seconds: 12), "retain owned service directory on failure: \(home.path)")
            if completed { try? FileManager.default.removeItem(at: home) }
        }
        run.start()
        try #require(waitForRecovery { FileManager.default.fileExists(atPath: acknowledgement.path) })
        let staleIdle = try Data(contentsOf: statusFile)
        let previousAcknowledgement = try Data(contentsOf: acknowledgement)
        try #require(readRecoveryStatus(statusFile)?.child.running == false)
        _ = try service.store.updateRecord { $0.leadership?.serving = true }
        try #require(entered.wait(timeout: .now() + 10) == .success,
                     "the real supervisor has read serving=true and reached Process.run")
        stopped.start(live: live, part: nil, seconds: 10, missingPeer: false)
        try #require(waitForRecovery { (try? service.store.readRecord().leadership?.serving) == false })
        // Rewriting ordinary idle status must not acknowledge the blocked
        // supervision cycle, even with a fresh inode and matching service PID.
        try staleIdle.write(to: statusFile, options: .atomic)
        requireFollowerLease(record: try service.store.readRecord(), running: true)
        #expect(!stopped.join(seconds: 0.3), "stale idle must not release the peer while a start is in flight")
        #expect(stopped.peerCalls == 0)
        #expect(try Data(contentsOf: acknowledgement) == previousAcknowledgement)
        try Data().write(to: directory.appendingPathComponent("release-replacement"))
        release.signal()
        try #require(stopped.join(seconds: 12))
        #expect(stopped.succeeded && stopped.peerCalls == 1)
        let final = try #require(readRecoveryStatus(statusFile))
        #expect(!final.serving && !final.child.running && final.child.starts == 1)
        requireFollowerLease(record: try service.store.readRecord(), running: false)
        #expect(try Data(contentsOf: acknowledgement) != previousAcknowledgement)
        run.requestStop()
        try #require(run.join(seconds: 10))
        #expect(try run.result())
        completed = true
    }

    @Test func stopDrainRecordIsOptionalAndNeverStartsAnAlreadyIdlePeer() throws {
        var record = ClusterSetupRecord()
        let legacyBytes = try JSONEncoder().encode(record)
        #expect(!String(decoding: legacyBytes, as: UTF8.self).contains("stopDrain"))
        #expect(try JSONDecoder().decode(ClusterSetupRecord.self, from: legacyBytes).stopDrain == nil)
        record.leadership = .init(role: "leader", leaderPin: "fixture-local", peerPin: "fixture-peer",
            peerName: "fixture", since: "fixture")
        record.stopDrain = .init(id: UUID(), keepPeerRunning: false)
        let roundTrip = try JSONDecoder().decode(ClusterSetupRecord.self, from: JSONEncoder().encode(record))
        #expect(roundTrip == record)
        requireFollowerLease(record: roundTrip, running: false)
        let missing = ClusterService.peerLeaseState(record: nil, mode: .cluster, leads: true)
        #expect(!missing.running && missing.serving == nil)
        record.stopDrain?.keepPeerRunning = true
        let notLeader = ClusterService.peerLeaseState(record: record, mode: .cluster, leads: false)
        #expect(!notLeader.running)
    }

    @Test func plannedStopRejectsUnknownLiveServiceAndDoesNotSignalRecycledIdentity() throws {
        let home = try NativePairMemberFixture.privateRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = try ClusterUserPaths(homeDirectory: home)
        let store = ClusterSetupStore(paths: .init(paths: paths))
        try ClusterConfigurationFiles.ensureDirectory(store.paths.directory, create: true, privateMode: true)
        #expect(ClusterService.stopLocalPart(in: store.paths.directory, seconds: 0), "no service or part is already idle")
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["30"]
        sleeper.standardInput = FileHandle.nullDevice; sleeper.standardOutput = FileHandle.nullDevice
        sleeper.standardError = FileHandle.nullDevice
        try sleeper.run()
        defer { if sleeper.isRunning { sleeper.terminate() }; sleeper.waitUntilExit() }
        let start = try #require(ClusterProcessTable.startTime(of: sleeper.processIdentifier))
        let stale = ClusterServiceStatus(role: "leader", serving: false, modelName: "fixture-model",
            sessionLeader: true, localRank: 0, setup: nil,
            child: .init(running: true, starts: 1, lastEnd: nil, restartInSeconds: nil, lastError: nil,
                         pid: sleeper.processIdentifier, startedAt: start - 5, solo: false),
            session: nil, control: nil, servicePID: -1)
        let statusFile = store.paths.directory.appendingPathComponent("service-status.json")
        try JSONEncoder().encode(stale).write(to: statusFile, options: .atomic)
        #expect(ClusterService.stopLocalPart(in: store.paths.directory, seconds: 0))
        #expect(sleeper.isRunning, "a recycled PID does not confer stop authority")
        try FileManager.default.removeItem(at: statusFile)
        let lockFile = store.paths.directory.appendingPathComponent("service.lock")
        let fd = open(lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        defer { _ = flock(fd, LOCK_UN); close(fd) }
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        #expect(!ClusterService.stopLocalPart(in: store.paths.directory, seconds: 0),
                "a live service with no trustworthy publication is not idle")
        #expect(sleeper.isRunning)
    }

    @Test func plannedStopDoesNotFollowAReplacementProcess() throws {
        let home = try NativePairMemberFixture.privateRoot()
        let helper = home.appendingPathComponent("service-part-fixture")
        try NativePairMemberFixture.helper().write(to: helper, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let paths = try ClusterUserPaths(homeDirectory: home)
        let store = ClusterSetupStore(paths: .init(paths: paths))
        try ClusterConfigurationFiles.ensureDirectory(store.paths.directory, create: true, privateMode: true)
        let statusFile = store.paths.directory.appendingPathComponent("service-status.json")
        var children: [Process] = []
        var completed = false
        let waiting = LocalPartStopRun()
        defer {
            for role in ["leftover", "replacement"] { try? Data().write(to: home.appendingPathComponent("release-\(role)")) }
            for child in children where child.isRunning { child.terminate() }
            #expect(waiting.join(seconds: 12))
            let ended = waitForRecovery { children.allSatisfy { !$0.isRunning } }
            #expect(ended, "retain owned fixture directory on failed cleanup: \(home.path)")
            if ended { children.forEach { $0.waitUntilExit() }; if completed { try? FileManager.default.removeItem(at: home) } }
        }
        for role in ["leftover", "replacement"] {
            let child = Process(); child.executableURL = helper
            child.arguments = ["--service-part-fixture", home.path, role]
            child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run(); children.append(child)
            try #require(waitForRecovery { readyPIDs(in: home, role: role) == [child.processIdentifier] })
        }
        func publish(_ child: Process) throws {
            let start = try #require(ClusterProcessTable.startTime(of: child.processIdentifier))
            let status = ClusterServiceStatus(role: "leader", serving: false, modelName: "fixture",
                sessionLeader: true, localRank: 0, setup: nil,
                child: .init(running: true, starts: 1, lastEnd: nil, restartInSeconds: nil, lastError: nil,
                             pid: child.processIdentifier, startedAt: start, solo: false),
                session: nil, control: nil, servicePID: -1)
            try JSONEncoder().encode(status).write(to: statusFile, options: .atomic)
        }
        try publish(children[0])
        waiting.start(directory: store.paths.directory)
        try #require(waitForRecovery { FileManager.default.fileExists(atPath: home.appendingPathComponent("leftover-\(children[0].processIdentifier).term").path) })
        try publish(children[1])
        try Data().write(to: home.appendingPathComponent("release-leftover"))
        try #require(waiting.join(seconds: 12))
        #expect(!waiting.succeeded, "a new identity must not inherit this stop operation")
        #expect(children[1].isRunning)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("replacement-\(children[1].processIdentifier).term").path))
        completed = true
    }

}

private final class ServiceRecoveryRun: @unchecked Sendable {
    private let service: ClusterService
    private let stop = DispatchSemaphore(value: 0)
    private let done = DispatchGroup()
    private let lock = NSLock()
    private var outcome: Result<Bool, Error>?
    private var lines: [String] = []
    init(service: ClusterService) { self.service = service }
    func start() {
        done.enter()
        Thread.detachNewThread { [self] in
            defer { done.leave() }
            let value = Result { try service.run(stop: stop) { [self] text in lock.withLock { lines.append(text) } } }
            lock.withLock { outcome = value }
        }
    }
    func requestStop() { stop.signal() }
    func join(seconds: Double) -> Bool { done.wait(timeout: .now() + seconds) == .success }
    func result() throws -> Bool {
        let value = try #require(lock.withLock { outcome })
        return try value.get()
    }
    var log: String { lock.withLock { lines.joined(separator: "\n") } }
}

/// The service loops here run their real supervision cycle every 0.1 s, not
/// every second. Those tests count cycles or wait on a published state, so a
/// shorter period changes no outcome, only the wall time.
/// `plannedStopRejectsStaleIdleWhileActualServiceStartsItsChild` keeps the
/// production second: it reads one idle acknowledgement and needs no further
/// cycle to replace it before the supervisor blocks.
private let serviceSupervisionInterval: Double = 0.1

private func waitForRecovery(seconds: Double = 10, _ predicate: () -> Bool) -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
    repeat {
        if predicate() { return true }
        usleep(20_000)
    } while DispatchTime.now().uptimeNanoseconds < deadline
    return predicate()
}

private func readRecoveryStatus(_ url: URL) -> ClusterServiceStatus? {
    guard let bytes = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(ClusterServiceStatus.self, from: bytes)
}

private func recoveryPublicationDate(_ url: URL) throws -> Date {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
}

private func nextRecoveryPublication(_ url: URL, after previous: Date) throws -> Date {
    try #require(waitForRecovery { (try? recoveryPublicationDate(url)).map { $0 > previous } ?? false },
                 "the service must complete another supervision/publication cycle")
    return try recoveryPublicationDate(url)
}

private func readyPIDs(in directory: URL, role: String) -> [Int32] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { $0.hasPrefix(role + "-") && $0.hasSuffix(".ready") }
        .compactMap { Int32($0.dropFirst(role.count + 1).dropLast(".ready".count)) }.sorted()
}

private func serviceAssertionTypes() throws -> [String] {
    var raw: Unmanaged<CFDictionary>?
    try #require(IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess)
    let values = try #require(raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]])
    return (values[NSNumber(value: getpid())] ?? []).compactMap {
        guard $0[kIOPMAssertionNameKey] as? String == "Darkbloom cluster: serving deployment" else { return nil }
        return $0[kIOPMAssertionTypeKey] as? String
    }.sorted()
}


private final class ServiceStopRun: @unchecked Sendable {
    private let done = DispatchGroup()
    private let lock = NSLock()
    private var calls = 0
    private var observedLive = false
    private var success = false
    func start(live: OnboardingLive, part: ClusterService.RecordedPart?, seconds: Double, missingPeer: Bool) {
        done.enter()
        Thread.detachNewThread { [self] in
            defer { done.leave() }
            let result = live.localStop(seconds: seconds) {
                lock.withLock { calls += 1; observedLive = ClusterService.runningPart(part) != nil }
                if missingPeer { throw ClusterSetupFailure("fixture peer unavailable") }
            }
            if case .success = result { lock.withLock { success = true } }
        }
    }
    func join(seconds: Double) -> Bool { done.wait(timeout: .now() + seconds) == .success }
    var peerCalls: Int { lock.withLock { calls } }
    var liveAtPeer: Bool { lock.withLock { observedLive } }
    var succeeded: Bool { lock.withLock { success } }
}


private final class LocalPartStopRun: @unchecked Sendable {
    private let done = DispatchGroup()
    private let lock = NSLock()
    private var success = false
    func start(directory: URL) {
        done.enter()
        Thread.detachNewThread { [self] in
            defer { done.leave() }
            let result = ClusterService.stopLocalPart(in: directory, seconds: 10)
            lock.withLock { success = result }
        }
    }
    func join(seconds: Double) -> Bool { done.wait(timeout: .now() + seconds) == .success }
    var succeeded: Bool { lock.withLock { success } }
}

/// Runs the actual outbound projection, accepted follower lease, saved-intent
/// decision and follower part selection. Only the physical transport is absent.
private func requireFollowerLease(record: ClusterSetupRecord, running: Bool) {
    let leader = "mac-aaaaaaaaaaaa", member = "mac-bbbbbbbbbbbb"
    let claim = ClusterControlClaim(term: 1, leaderID: leader, members: [leader, member], reason: "fixture")
    let facts = [leader, member].map { ClusterControlMember(memberID: $0, name: "fixture", memoryBytes: 1, gpuCores: 1) }
    var follower = ClusterControlNode(localID: member, members: facts, claim: claim,
        rankOrder: [leader, member], now: 0, ttl: 10)
    let projected = ClusterService.peerLeaseState(record: record, mode: .cluster, leads: true)
    #expect(projected.running == running && projected.serving == running)
    let received = follower.receiveLease(from: leader, offered: claim, running: projected.running, facts: facts, now: 1)
    var savedServing = true
    if let intent = ClusterControlIntent.toRecord(answer: received.answer, leaderServing: projected.serving, recorded: savedServing) {
        savedServing = intent
    }
    let wanted = ClusterControlPartChoice.want(mode: follower.mode(now: 1), serving: savedServing,
        hasSetup: true, leaderRunsCluster: follower.leaderRunsCluster, runningSolo: false, model: "fixture")
    #expect(wanted == (running ? .cluster : .none))
}
