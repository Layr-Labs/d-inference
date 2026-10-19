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
                paths: paths, recoveryGraceSeconds: 0.2)
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
