import DarkbloomClusterProcess
import DarkbloomClusterRemote
import Darwin
import Foundation
import Testing
@testable import ProviderCore

/// Leader failover, finish (2026-10-13 night): the solo readiness check names its own server, verify-teardown counts
/// only this cluster's processes, a rank 0 told to stop while it waits for its follower stops waiting, and the cluster
/// service's status carries what the command line needs to tell a live, confirmed leader from a stale file.
/// Loopback and this process's own children only: no cable, no peer Mac, no model.
@Suite(.serialized) struct ClusterLeaderFailoverFinishTests {
    // MARK: - (f) a stop during start ends the follower wait

    @Test func startWaitEndsWithinOneSliceOfACancel() {
        var clock: UInt64 = 0
        var attempts = 0
        let outcome = ClusterStartWait.wait(until: 30_000_000_000, slice: 200_000_000, cancelled: { attempts >= 3 },
                                            attempt: { slice in attempts += 1; clock += slice; return false }, now: { clock })
        #expect(outcome == .cancelled)
        #expect(attempts == 3 && clock == 600_000_000, "cancelled after three 0.2 s slices, not at the 30 s deadline")
    }

    @Test func startWaitStillTimesOutAndSucceeds() {
        var clock: UInt64 = 0
        #expect(ClusterStartWait.wait(until: 1_000_000_000, cancelled: { false },
                                      attempt: { clock += $0; return false }, now: { clock }) == .timedOut)
        #expect(clock == 1_000_000_000, "the last slice is cut to the deadline")
        var tries = 0
        #expect(ClusterStartWait.wait(until: .max, cancelled: { false }, attempt: { _ in tries += 1; return tries == 2 }, now: { 0 }) == .ready)
    }

    // MARK: - (b) the solo readiness check names THIS service's solo server

    /// A loopback HTTP responder in this process: every connection gets one 200 with an empty model list.
    final class Responder: @unchecked Sendable {
        let fd: Int32
        let port: Int
        private var running = true
        init() throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = 0
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard bound == 0, listen(fd, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
            self.fd = fd
            port = Int(UInt16(bigEndian: address.sin_port))
            let listener = fd
            Thread.detachNewThread { [weak self] in
                while self?.running == true {
                    let client = accept(listener, nil, nil)
                    guard client >= 0 else { return }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    _ = read(client, &buffer, buffer.count)
                    let body = #"{"object":"list","data":[]}"#
                    let reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                    _ = reply.withCString { write(client, $0, strlen($0)) }
                    close(client)
                }
            }
        }
        func stop() { running = false; shutdown(fd, SHUT_RDWR); close(fd) }
    }

    static func status(pid: Int32?, startedAt: Double?, solo: Bool = true) -> ClusterServiceStatus {
        .init(role: "leader", serving: true, modelName: "m", sessionLeader: false, localRank: nil, setup: nil,
              child: .init(running: true, starts: 1, lastEnd: nil, restartInSeconds: nil, lastError: nil, pid: pid, startedAt: startedAt, solo: solo),
              session: nil, control: nil, servicePID: getpid())
    }

    @Test func listeningPortsAndDescendantsComeFromTheKernelTables() throws {
        let responder = try Responder()
        defer { responder.stop() }
        #expect(ClusterProcessTable.listeningTCPPorts(of: getpid()).contains(responder.port), "this process listens on its port")
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate(); sleeper.waitUntilExit() }
        #expect(ClusterProcessTable.descendants(of: getpid()).contains(sleeper.processIdentifier), "a child is a descendant")
        #expect(!ClusterProcessTable.listeningTCPPorts(of: sleeper.processIdentifier).contains(responder.port), "the child does not listen there")
        #expect(ClusterProcessTable.executablePath(of: sleeper.processIdentifier) == "/bin/sleep")
    }

    @Test func soloReadinessIsOursOnlyWhenOurSoloProcessHoldsThePort() throws {
        let responder = try Responder()
        defer { responder.stop() }
        // The published solo server is this process (it holds the listener): ready.
        let me = getpid()
        let started = try #require(ClusterProcessTable.startTime(of: me))
        #expect(ClusterService.soloReadiness(Self.status(pid: me, startedAt: started), port: responder.port) == .ready)
        // The published solo server is another process of ours that does NOT hold the port, while something answers
        // there: another program's server is never taken for ours.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate(); sleeper.waitUntilExit() }
        let sleeperStart = try #require(ClusterProcessTable.startTime(of: sleeper.processIdentifier))
        #expect(ClusterService.soloReadiness(Self.status(pid: sleeper.processIdentifier, startedAt: sleeperStart), port: responder.port) == .foreign)
        // A recycled process number (another start time), no solo child, or a cluster part: never ready.
        #expect(ClusterService.soloReadiness(Self.status(pid: me, startedAt: started - 10), port: responder.port) == .loading)
        #expect(ClusterService.soloReadiness(Self.status(pid: nil, startedAt: nil), port: responder.port) == .loading)
        #expect(ClusterService.soloReadiness(Self.status(pid: me, startedAt: started, solo: false), port: responder.port) == .loading)
        #expect(ClusterService.soloReadiness(nil, port: responder.port) == .loading)
    }

    @Test func publishedStatusDecodesWithoutTheNewFields() throws {
        // A status written by the previous build (no pid, servicePID, confirmed or soloInSeconds) still decodes.
        let old = #"{"serving":true,"sessionLeader":false,"child":{"running":false,"starts":0},"control":{"leaderID":"mac-a","leaderName":"A","term":1,"reason":"r","leads":true,"line":"l","mode":"cluster"}}"#
        let decoded = try JSONDecoder().decode(ClusterServiceStatus.self, from: Data(old.utf8))
        #expect(decoded.control?.confirmed == nil && decoded.servicePID == nil && decoded.child.pid == nil)
        let now = Self.status(pid: 7, startedAt: 1.5)
        #expect(try JSONDecoder().decode(ClusterServiceStatus.self, from: JSONEncoder().encode(now)) == now)
    }

    // MARK: - (e) verify-teardown counts this cluster's processes only

    static let me = "mac-0123456789ab", other = "mac-ba9876543210", ownExecutable = "/Applications/Darkbloom.app/Contents/MacOS/darkbloom"

    static func worker(_ pid: Int32, parent: Int32, peers: [String]?, path: String = "/x/darkbloom-cluster-worker") -> ClusterProcessTable.Entry {
        var arguments = [path, "--rank", "1", "--membership-epoch", UUID().uuidString]
        if let peers { arguments += ["--peer0-id", peers[0], "--peer0-build-sha256", "00", "--peer1-id", peers[1], "--peer1-build-sha256", "00"] }
        return .init(processIdentifier: pid, arguments: arguments, parentProcessIdentifier: parent, executableName: "darkbloom-cluster-worker", startedAt: 1)
    }

    static func owner(_ pid: Int32, parent: Int32, path: String) -> ClusterProcessTable.Entry {
        .init(processIdentifier: pid, arguments: [path, "cluster", "worker-owner", "--stdio"], parentProcessIdentifier: parent,
              executableName: "darkbloom", startedAt: 1)
    }

    @Test func teardownCountsOnlyThisClustersProcesses() {
        let scope = ClusterTeardownVerification.Scope(memberID: Self.me, ownerExecutables: [Self.ownExecutable])
        let paths: [Int32: String] = [10: Self.ownExecutable, 20: "/tmp/check/darkbloom", 30: "/tmp/other-install/darkbloom"]
        let processes = [
            Self.owner(10, parent: 1, path: Self.ownExecutable),                         // our orphaned owner: counted
            Self.worker(11, parent: 1, peers: [Self.me, Self.other]),                     // our orphaned worker: counted
            Self.worker(21, parent: 900, peers: nil, path: "/tmp/check/darkbloom-cluster-worker"),   // a check's fake worker
            Self.worker(22, parent: 900, peers: ["mac-fake00000001", "mac-fake00000002"]),        // another identity's worker
            Self.owner(30, parent: 901, path: "/tmp/other-install/darkbloom"),          // another install's owner, no worker of ours
            Self.owner(31, parent: 1, path: "/tmp/moved/darkbloom"),                    // an owner of ours by its worker
            Self.worker(32, parent: 31, peers: [Self.other, Self.me]),
        ]
        let report = ClusterTeardownVerification.report(at: 0, processes: processes, liveEpochs: [], protectedProcessIdentifiers: [],
            wired: nil, journal: "absentOrEmpty", staleBootstrapDirectories: [], scope: scope, executablePath: { paths[$0] })
        #expect(report.processes.map(\.processIdentifier) == [10, 11, 31, 32], "this cluster's: \(report.processes.map(\.processIdentifier))")
        #expect(report.otherClusters.map(\.processIdentifier) == [21, 22, 30], "listed apart: \(report.otherClusters.map(\.processIdentifier))")
        #expect(!report.passed && report.reasons.first == "4 cluster process(es) still running")
        // Only another home's processes running: clean.
        let others = ClusterTeardownVerification.report(at: 0, processes: [processes[2], processes[3], processes[4]], liveEpochs: [],
            protectedProcessIdentifiers: [], wired: nil, journal: "absentOrEmpty", staleBootstrapDirectories: [], scope: scope,
            executablePath: { paths[$0] })
        #expect(others.passed && others.processes.isEmpty && others.otherClusters.count == 3)
        // No pairing (no identity known): every cluster process counts, as before.
        let unscoped = ClusterTeardownVerification.report(at: 0, processes: processes, liveEpochs: [], protectedProcessIdentifiers: [],
            wired: nil, journal: "absentOrEmpty", staleBootstrapDirectories: [], scope: .init(memberID: nil, ownerExecutables: []),
            executablePath: { paths[$0] })
        #expect(unscoped.processes.count == 7 && unscoped.otherClusters.isEmpty)
    }

    @Test func theProductScopeNamesThisInstallsExecutable() {
        let scope = ClusterOrphanSweep.scope(memberID: Self.me, executablePath: "/opt/link/darkbloom")
        #expect(scope.memberID == Self.me && scope.ownerExecutables.contains("/opt/link/darkbloom"))
        #expect(scope.ownerExecutables.contains { $0 == ClusterProcessTable.executablePath(of: getpid()) }, "this process's own file")
    }

    // MARK: - (a)/(3) the service's choices come from the pure control node

    @Test func serviceGraceAndLeaderCommands() {
        #expect(ClusterService.actsAsLeader(.adopt) && ClusterService.actsAsLeader(.serve) && ClusterService.actsAsLeader(.stop)
                && ClusterService.actsAsLeader(.reachMembers))
        #expect(!ClusterService.actsAsLeader(.status) && !ClusterService.actsAsLeader(.readiness) && !ClusterService.actsAsLeader(.test)
                && !ClusterService.actsAsLeader(.verifyTeardown) && !ClusterService.actsAsLeader(.planModels))
        let grace = ClusterService.soloGraceSeconds
        #expect(grace >= 0 && grace <= 3600, "the grace is 600 s unless a developer build was given an override: \(grace)")
        #expect(abs(ClusterService.monotonicSeconds() - ClusterControlClock.seconds()) < 0.05, "the service runs on the continuous clock")
    }
}
