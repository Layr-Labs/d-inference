import Foundation
import Darwin
@testable import InstalledContract
import DarkbloomClusterRemote

/// The leader's control of its member's pair cache over the real link control
/// channel on loopback, with the member in a SECOND PROCESS (this binary run
/// as `--member-cache-child`): the leader's cache settings reach the member
/// and its owner applies them; when the leader unpairs, the member removes the
/// pair's prefix-tier records and keeps its single-Mac cache. Also: where an
/// installed provider finds its cluster worker (the release's Contents/Helpers).
extension ClusterConsoleCheck {
    static let memberCachePort: UInt16 = 45_893
    static let memberCacheLeaderPin = "1111222233334444aaaabbbbccccdddd"
    static let memberCacheMemberPin = "5555666677778888eeeeffff00001111"
    static let memberCacheClusterID = "pair-0123456789ab"

    static func memberCachePairing(local: String, peer: String) -> ClusterSetupLinkExchange.Pairing {
        .init(localPin: local, peerPin: peer, clusterID: memberCacheClusterID,
              linkEpoch: "6a1d2c3b-4e5f-4a6b-8c7d-9e0f1a2b3c4d", edgeID: "0b1c2d3e-4f5a-4b6c-8d7e-9f0a1b2c3d4e",
              secretFile: "/private/link/edge.secret", secret: Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 5) }))
    }

    static func memberCacheSettings(home: URL) -> ClusterPrefixCacheSettings {
        .init(root: ClusterPrefixCacheSettings.defaultRoot(home: home))
    }

    static func memberCacheStore(home: URL) -> ClusterMemberCacheControl.Store {
        .init(directory: home.appendingPathComponent(".darkbloom/cluster-setup", isDirectory: true))
    }

    /// The member side, in its own process: the cluster service's command
    /// handling for the two cache operations, over the real responder.
    /// Arguments: home directory, "follows" or "stranger". Runs until standard input closes.
    static func memberCacheChild(_ arguments: [String]) -> Never {
        guard arguments.count == 2, let selection = try? ClusterLinkInterfaceAdmission.select(interface: "lo0",
            localAddress: nil, peerAddress: nil, policy: .loopbackForTests, inspector: ClusterLinkSystemInterfaceInspector()) else {
            print("child: bad arguments or no lo0"); exit(64)
        }
        let home = URL(fileURLWithPath: arguments[0], isDirectory: true), follows = arguments[1] == "follows"
        let store = memberCacheStore(home: home)
        let pairing = memberCachePairing(local: memberCacheMemberPin, peer: memberCacheLeaderPin)
        @Sendable func status() -> ClusterServiceStatus {
            .init(role: "member", serving: false, modelName: nil, sessionLeader: false, localRank: 1, setup: nil,
                  child: .init(running: false, starts: 0), session: nil,
                  cacheSync: store.digest(leaderPin: memberCacheLeaderPin))
        }
        do {
            let responder = try ClusterSetupLinkExchange.Responder(pairing: pairing, selection: selection, port: memberCachePort,
                policy: .loopbackForTests, answer: { throw ClusterSetupFailure("no report in this check") },
                receive: { _ in throw ClusterSetupFailure("no inbox in this check") },
                command: { data in
                    let command = try JSONDecoder().decode(ClusterServiceCommand.self, from: data)
                    if command.op == .status { return try JSONEncoder().encode(status()) }
                    guard let reply = try ClusterMemberCacheControl.handle(command, follows: follows,
                        leaderPin: pairing.peerPin, pairClusterID: pairing.clusterID,
                        memberSettings: { memberCacheSettings(home: home) }, store: store, status: status) else {
                        throw ClusterSetupFailure("not a cache command")
                    }
                    return reply
                })
            try responder.start()
            print("ready"); fflush(stdout)
            _ = FileHandle.standardInput.readDataToEndOfFile()
            responder.stop()
            exit(0)
        } catch {
            print("child: \(error)"); exit(1)
        }
    }

    final class MemberCacheChildProcess {
        let process = Process()
        let input = Pipe(), output = Pipe()
        init(home: URL, follows: Bool) throws {
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--member-cache-child", home.path, follows ? "follows" : "stranger"]
            process.standardInput = input; process.standardOutput = output
            try process.run()
            // Wait for "ready" (the responder listens), bounded.
            var seen = Data()
            let deadline = Date().addingTimeInterval(20)
            while !String(decoding: seen, as: UTF8.self).contains("ready"), Date() < deadline, process.isRunning {
                seen.append(output.fileHandleForReading.availableData)
            }
        }
        func stop() {
            try? input.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning { process.terminate() }
        }
    }

    static func memberCacheControl() throws {
        try bundledWorkerPath()
        try memberCacheLocal()
        try memberCacheTwoProcesses()
    }

    /// Where an installed provider finds its cluster worker when no setup names one.
    static func bundledWorkerPath() throws {
        typealias H = ClusterBundledHelpers
        expectEqual(H.defaultWorker(darkbloomExecutable: URL(fileURLWithPath: "/A/Darkbloom.app/Contents/MacOS/darkbloom")).path,
                    "/A/Darkbloom.app/Contents/Helpers/darkbloom-cluster-worker", "a release finds the worker in the app's Helpers")
        expectEqual(H.defaultWorker(darkbloomExecutable: URL(fileURLWithPath: "/opt/bench/darkbloom")).path,
                    "/opt/bench/worker/darkbloom-cluster-worker", "a development build keeps worker/ beside darkbloom")
        // The installer exposes darkbloom through a bin/ symlink: resolved first.
        let root = scratch.appendingPathComponent("installed", isDirectory: true)
        let macOS = root.appendingPathComponent("Darkbloom.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: macOS.appendingPathComponent("darkbloom").path, contents: Data("x".utf8))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("bin/darkbloom").path,
                                                   withDestinationPath: "../Darkbloom.app/Contents/MacOS/darkbloom")
        let viaLink = H.defaultWorker(darkbloomExecutable: root.appendingPathComponent("bin/darkbloom"))
        expect(viaLink.path.hasSuffix("/installed/Darkbloom.app/Contents/Helpers/darkbloom-cluster-worker"),
               "a symlinked launch still finds the app's Helpers: \(viaLink.path)")
        expect(H.missingWorkerReason(darkbloomExecutable: root.appendingPathComponent("bin/darkbloom")).contains("Contents/Helpers"),
               "a missing bundled worker names the app's Helpers")
    }

    /// The decisions and the owner's view, in this process.
    static func memberCacheLocal() throws {
        typealias C = ClusterMemberCacheControl
        let home = scratch.appendingPathComponent("local-member", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = memberCacheStore(home: home), own = memberCacheSettings(home: home)
        let leader = ClusterCacheSettingsSync(prefixCacheEnabled: true, dailyWriteGB: 750, diskBudgetGB: nil, ttlSeconds: 1_800)
        expect(C.settingsToSend(leader: leader, memberDigest: nil) == leader, "a member that applied nothing is sent the settings")
        expect(C.settingsToSend(leader: leader, memberDigest: C.digest(leader)) == nil, "a member in sync is sent nothing")
        expect(C.settingsToSend(leader: leader, memberDigest: String(repeating: "0", count: 64)) == leader, "another digest: sent again")
        expectEqual(C.digest(leader).count, 64, "the digest is SHA-256 hex")
        expect(C.digest(leader) != C.digest(.init(prefixCacheEnabled: false, dailyWriteGB: 750, ttlSeconds: 1_800)),
               "the digest follows every choice")
        // Nothing synced: the owner keeps this Mac's own.
        expectEqual(C.effective(own: own, store: store, followedLeaderPin: memberCacheLeaderPin), own, "nothing synced: own settings")
        // Refusals: a stranger, out-of-bounds values, another cluster.
        let refused: [(ClusterServiceCommand, Bool, String)] = [
            (.init(op: .cacheSettings, cache: leader), false, "a Mac this one does not follow"),
            (.init(op: .cacheSettings), true, "no settings"),
            (.init(op: .cacheSettings, cache: .init(prefixCacheEnabled: true, ttlSeconds: 5_000)), true, "a TTL beyond 30 minutes"),
            (.init(op: .unpair, clusterID: "pair-ffffffffffff"), true, "another cluster's unpair"),
            (.init(op: .unpair, clusterID: memberCacheClusterID), false, "an unpair from a Mac this one does not follow"),
        ]
        for (command, follows, what) in refused {
            do {
                _ = try C.handle(command, follows: follows, leaderPin: memberCacheLeaderPin, pairClusterID: memberCacheClusterID,
                                 memberSettings: { own }, store: store, status: { fatalError("no status on a refusal") })
                expect(false, "refused: \(what)")
            } catch { expect(true, "refused: \(what)") }
        }
        expect(store.load(leaderPin: memberCacheLeaderPin) == nil, "a refusal keeps nothing")
        expect(try C.handle(.init(op: .status), follows: true, leaderPin: memberCacheLeaderPin, pairClusterID: memberCacheClusterID,
                            memberSettings: { own }, store: store, status: { fatalError() }) == nil, "other operations are not cache commands")
    }

    /// Leader here, member in a second process, over the authenticated link channel on loopback.
    static func memberCacheTwoProcesses() throws {
        typealias C = ClusterMemberCacheControl
        typealias X = ClusterSetupLinkExchange
        guard let selection = try? ClusterLinkInterfaceAdmission.select(interface: "lo0", localAddress: nil, peerAddress: nil,
            policy: .loopbackForTests, inspector: ClusterLinkSystemInterfaceInspector()) else { expect(false, "lo0 selection"); return }
        let home = scratch.appendingPathComponent("member-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let caches = home.appendingPathComponent("Library/Caches/darkbloom", isDirectory: true)
        // The member's single-Mac tier and the pair's tier (one plan, rank 1, one record, a staging directory).
        let singleMac = caches.appendingPathComponent("kv3/ab/record.bin")
        try FileManager.default.createDirectory(at: singleMac.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("single-Mac record".utf8).write(to: singleMac)
        let root = ClusterPrefixCacheSettings.defaultRoot(home: home)
        let plan = root.appendingPathComponent("v1-" + String(repeating: "a", count: 24), isDirectory: true)
        try FileManager.default.createDirectory(at: plan.appendingPathComponent("rank1"), withIntermediateDirectories: true)
        try Data("pair record".utf8).write(to: plan.appendingPathComponent("rank1/" + String(repeating: "b", count: 32) + ".dbpx"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("staging/0123"), withIntermediateDirectories: true)
        expectEqual(ClusterPrefixSSDInspection.inspect(root: root).records, 1, "the member holds one pair record before")

        let member = try MemberCacheChildProcess(home: home, follows: true)
        defer { member.stop() }
        expect(member.process.isRunning, "the member process is up")
        let leaderPairing = memberCachePairing(local: memberCacheLeaderPin, peer: memberCacheMemberPin)
        func send(_ command: ClusterServiceCommand) throws -> Data {
            try X.command(pairing: leaderPairing, selection: selection, peerAddress: nil, body: try JSONEncoder().encode(command),
                          seconds: 10, port: memberCachePort, policy: .loopbackForTests).reply
        }

        // 1. Sync: the member reports no digest; the leader sends its choices; the member applies and reports them.
        let before = try JSONDecoder().decode(ClusterServiceStatus.self, from: try send(.init(op: .status)))
        expect(before.cacheSync == nil, "the member applied no settings yet")
        let leader = ClusterCacheSettingsSync(prefixCacheEnabled: false, dailyWriteGB: 100, diskBudgetGB: 64, ttlSeconds: 600)
        let toSend = try require2(C.settingsToSend(leader: leader, memberDigest: before.cacheSync), "the leader has settings to send")
        let applied = try JSONDecoder().decode(ClusterServiceStatus.self, from: try send(.init(op: .cacheSettings, cache: toSend)))
        expectEqual(applied.cacheSync, C.digest(leader), "the member reports the leader's digest")
        expect(C.settingsToSend(leader: leader, memberDigest: applied.cacheSync) == nil, "the next sync sends nothing")
        // What the member's owner gives its rank: its own root, the leader's choices.
        let store = memberCacheStore(home: home)
        let effective = C.effective(own: memberCacheSettings(home: home), store: store, followedLeaderPin: memberCacheLeaderPin)
        expect(!effective.prefixCacheEnabled && effective.dailyWriteBytes == 100_000_000_000 && effective.ttlSeconds == 600
               && effective.byteBudget == 64 * 1_073_741_824, "the member's owner applies the leader's choices")
        expectEqual(effective.root, root, "the root never travels: the member's own")
        expectEqual(C.effective(own: memberCacheSettings(home: home), store: store, followedLeaderPin: "another-leader"),
                    memberCacheSettings(home: home), "another leader's settings are never applied")
        var info = stat()
        expect(lstat(home.appendingPathComponent(".darkbloom/cluster-setup/" + C.syncFileName).path, &info) == 0
               && info.st_mode & 0o077 == 0, "the synced settings are owner-only")
        // Out of bounds: refused by the member, which keeps what it had.
        do { _ = try send(.init(op: .cacheSettings, cache: .init(prefixCacheEnabled: true, ttlSeconds: 9_999))); expect(false, "bad TTL refused") }
        catch { expect(String(describing: error).contains("refused"), "the member refuses a bad TTL: \(error)") }
        expectEqual(store.digest(leaderPin: memberCacheLeaderPin), C.digest(leader), "and keeps the settings it had")

        // 2. Unpair naming another cluster: refused, nothing removed.
        do { _ = try send(.init(op: .unpair, clusterID: "pair-ffffffffffff")); expect(false, "another cluster's unpair refused") }
        catch { expect(true, "another cluster's unpair refused") }
        expect(FileManager.default.fileExists(atPath: plan.path), "the pair's records stay after a refused unpair")

        // 3. A live rank holds the plan: kept and marked; the rest goes.
        let lock = Darwin.open(plan.appendingPathComponent("in-use").path, O_RDWR | O_CREAT, 0o600)
        expect(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0, "this process plays the live rank")
        let held = try JSONDecoder().decode(C.UnpairReply.self, from: try send(.init(op: .unpair, clusterID: memberCacheClusterID)))
        expect(held.keptLive == 1 && held.removedPlans == 0 && held.settingsForgotten, "a live rank's plan is kept: \(held)")
        expect(store.reclaimPending, "and its reclaim is pending")
        expect(store.load(leaderPin: memberCacheLeaderPin) == nil, "the leader's settings are forgotten")
        _ = flock(lock, LOCK_UN); Darwin.close(lock)
        // The rank ended: the member's service finishes the reclaim.
        let finished = C.finishPendingReclaim(root: root, store: store)
        expect(finished?.removedPlans == 1 && finished?.keptLive == 0 && !store.reclaimPending, "the pending reclaim finished")
        expect(!FileManager.default.fileExists(atPath: plan.path), "the pair's plan is gone")
        expect(!FileManager.default.fileExists(atPath: root.path), "and the pair's root with it")
        expectEqual(try Data(contentsOf: singleMac), Data("single-Mac record".utf8), "the single-Mac cache is untouched")

        // 4. A fresh pair cache, nothing live: one unpair removes it at once.
        try FileManager.default.createDirectory(at: plan.appendingPathComponent("rank1"), withIntermediateDirectories: true)
        try Data("pair record".utf8).write(to: plan.appendingPathComponent("rank1/" + String(repeating: "c", count: 32) + ".dbpx"))
        let clean = try JSONDecoder().decode(C.UnpairReply.self, from: try send(.init(op: .unpair, clusterID: memberCacheClusterID)))
        expect(clean.removedPlans == 1 && clean.keptLive == 0 && clean.rootRemoved && clean.problems.isEmpty, "unpair reclaims: \(clean)")
        expect(!FileManager.default.fileExists(atPath: root.path), "nothing of the pair's tier is left")
        expect(FileManager.default.fileExists(atPath: singleMac.path), "the single-Mac cache is still untouched")
        member.stop()

        // 5. A member that does not follow the asking Mac refuses both commands.
        try FileManager.default.createDirectory(at: plan.appendingPathComponent("rank1"), withIntermediateDirectories: true)
        let stranger = try MemberCacheChildProcess(home: home, follows: false)
        defer { stranger.stop() }
        for command in [ClusterServiceCommand(op: .cacheSettings, cache: leader), .init(op: .unpair, clusterID: memberCacheClusterID)] {
            do { _ = try send(command); expect(false, "a non-follower refuses \(command.op)") }
            catch { expect(String(describing: error).contains("does not follow"), "a non-follower refuses \(command.op): \(error)") }
        }
        expect(FileManager.default.fileExists(atPath: plan.path), "a non-follower keeps its pair cache")
    }

    /// `#require` for the check runner: the value, or a recorded failure and a throw.
    static func require2<T>(_ value: T?, _ message: String, line: Int = #line) throws -> T {
        guard let value else { expect(false, message, line: line); throw ClusterSetupFailure(message) }
        return value
    }
}
