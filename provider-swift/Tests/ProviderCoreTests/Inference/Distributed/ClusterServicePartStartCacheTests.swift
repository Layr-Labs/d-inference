import CryptoKit
import Darwin
import Foundation
import Testing
@testable import ProviderCore

/// The actual cluster service loop starting the follower's part of a saved pair setup. The follower runs no API
/// port probe, and its pairing is moved away, so nothing listens. The part is `/usr/bin/true`; nothing loads a model.
/// The model folder holds a weight file and one a folder down (MiMo's `audio_tokenizer/`), both in the file cache as
/// a copy, a download or an earlier start leaves them. A rank that loads its share against a cache full of its own
/// model makes macOS compress other memory, and past the load gate's 512 MiB guard every later decision of that load
/// counts no cache and is refused; each restart read the model back in and was refused again (MiMo on two 128 GB
/// Macs, 680 of 680 starts, 2026-11-01).
@Suite("Cluster service: the model's file cache at a part start", .serialized)
struct ClusterServicePartStartCacheTests {
    @Test func aPartStartsWithItsModelsPagesOutOfTheFileCache() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        // The setups pin the worker this Mac has installed, as after the leader's sync for the build it runs.
        try macs.readopt(runtime: Self.sha256(macs.follower.worker))
        try withExtendedLifetime(macs) {
            let follower = macs.follower, leader = macs.leader
            let folder = follower.model
            let nested = folder.appendingPathComponent("audio_tokenizer", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let files = [(folder.appendingPathComponent("model-00001-of-00001.safetensors"), Self.bytes(64 << 20, seed: 1)),
                         (nested.appendingPathComponent("model.safetensors"), Self.bytes(32 << 20, seed: 2))]
            for (url, data) in files {
                try data.write(to: url, options: .withoutOverwriting)
                try Self.readThroughCache(url)
                try #require(Self.residentShare(url) > 0.9, "a file just read stays in this Mac's cache: \(url.lastPathComponent)")
            }
            // Only the part under test runs: no paired Mac is answered.
            try FileManager.default.moveItem(at: follower.pairing.directory,
                                             to: follower.home.appendingPathComponent("pairing-elsewhere", isDirectory: true))
            let atStart = ClusterApprovalRecorder<[Double]>()
            let wizard = ClusterSetupOperations.LiveSettings(providerConfiguration: follower.provider,
                darkbloomExecutable: URL(fileURLWithPath: "/usr/bin/true"), sessionArguments: [], pair: nil, dryRun: true,
                version: "fixture")
            let service = ClusterService(settings: .init(wizard: wizard, leaderArguments: [], followerArguments: []),
                paths: follower.paths, recoveryGraceSeconds: 0.2, supervisionIntervalSeconds: 0.1,
                beforePartStart: { atStart.append(files.map { Self.residentShare($0.0) }) },
                // Its power assertions apart from those of the other services this test process runs.
                powerAssertionReason: "Cluster part-start cache test " + UUID().uuidString)
            var leadership = ClusterOnboardingLeadership(role: "member", leaderPin: leader.pin, peerPin: leader.pin,
                peerName: "fixture leader", since: "fixture")
            leadership.serving = true; leadership.modelName = ClusterApprovalMacs.model
            _ = try service.store.updateRecord { $0.leadership = leadership }
            // A real control node that accepted the leader's lease saying the cluster runs: this Mac runs its part.
            let now = ClusterService.monotonicSeconds()
            let claim = ClusterControlClaim(term: 1, leaderID: leader.memberID, members: [leader.memberID, follower.memberID],
                                            reason: "fixture")
            var node = ClusterControlNode(localID: follower.memberID,
                members: [.init(memberID: follower.memberID, name: "fixture", memoryBytes: 1, gpuCores: 1),
                          .init(memberID: leader.memberID, name: "fixture leader", memoryBytes: 1, gpuCores: 1)],
                claim: claim, rankOrder: [leader.memberID, follower.memberID], now: now, ttl: 3_600)
            _ = node.receiveLease(from: leader.memberID, offered: claim, running: true, facts: [], now: now)
            try #require(node.leaderRunsCluster)
            service.lock.withLock { service.control = node }

            let stop = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            let lines = ClusterApprovalRecorder<String>()
            Thread.detachNewThread {
                _ = try? service.run(stop: stop) { lines.append($0) }
                done.signal()
            }
            let deadline = Date().addingTimeInterval(20)
            while atStart.values.isEmpty, Date() < deadline { usleep(20_000) }
            stop.signal()
            #expect(done.wait(timeout: .now() + 30) == .success, "the service did not stop")

            let shares = try #require(atStart.values.first, "the part did not start: \(lines.values)")
            for ((url, _), share) in zip(files, shares) {
                #expect(share < 0.1, "\(url.lastPathComponent) was \(Int(share * 100)) % in the file cache when the part started")
            }
            for (url, data) in files { #expect(try Data(contentsOf: url) == data, "\(url.lastPathComponent) changed") }
        }
    }

    /// R5-4 (M5 Ultra pair, 0.10.7 → 0.10.8): after an update the member's saved setup still pins the previous
    /// build's worker. Its part refused the installed inputs and ended at once, six times, until the leader synced the
    /// setup for the new build. The member now waits for that setup, says so once, and starts nothing.
    @Test func aMemberWhoseSetupPinsAnEarlierWorkerWaitsForTheLeadersSetup() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        try withExtendedLifetime(macs) {
            let follower = macs.follower, leader = macs.leader
            try #require(try Self.sha256(follower.worker) != macs.saved(follower).capability.runtimeBinarySHA256)
            try FileManager.default.moveItem(at: follower.pairing.directory,
                                             to: follower.home.appendingPathComponent("pairing-elsewhere", isDirectory: true))
            let starts = ClusterApprovalRecorder<Int>()
            let wizard = ClusterSetupOperations.LiveSettings(providerConfiguration: follower.provider,
                darkbloomExecutable: URL(fileURLWithPath: "/usr/bin/true"), sessionArguments: [], pair: nil, dryRun: true,
                version: "fixture")
            let service = ClusterService(settings: .init(wizard: wizard, leaderArguments: [], followerArguments: []),
                paths: follower.paths, recoveryGraceSeconds: 0.2, supervisionIntervalSeconds: 0.1,
                beforePartStart: { starts.append(1) },
                powerAssertionReason: "Cluster member setup wait test " + UUID().uuidString)
            var leadership = ClusterOnboardingLeadership(role: "member", leaderPin: leader.pin, peerPin: leader.pin,
                peerName: "fixture leader", since: "fixture")
            leadership.serving = true; leadership.modelName = ClusterApprovalMacs.model
            _ = try service.store.updateRecord { $0.leadership = leadership }
            let now = ClusterService.monotonicSeconds()
            let claim = ClusterControlClaim(term: 1, leaderID: leader.memberID, members: [leader.memberID, follower.memberID],
                                            reason: "fixture")
            var node = ClusterControlNode(localID: follower.memberID,
                members: [.init(memberID: follower.memberID, name: "fixture", memoryBytes: 1, gpuCores: 1),
                          .init(memberID: leader.memberID, name: "fixture leader", memoryBytes: 1, gpuCores: 1)],
                claim: claim, rankOrder: [leader.memberID, follower.memberID], now: now, ttl: 3_600)
            _ = node.receiveLease(from: leader.memberID, offered: claim, running: true, facts: [], now: now)
            try #require(node.leaderRunsCluster)
            service.lock.withLock { service.control = node }

            let stop = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            let lines = ClusterApprovalRecorder<String>()
            Thread.detachNewThread {
                _ = try? service.run(stop: stop) { lines.append($0) }
                done.signal()
            }
            let wait = ClusterOnboardingUpdate.memberWaitLine(version: ProviderCore.version)
            let deadline = Date().addingTimeInterval(20)
            while !lines.values.contains(wait), starts.values.isEmpty, Date() < deadline { usleep(20_000) }
            // Further ticks: still nothing starts, and the wait is said once.
            usleep(1_000_000)
            let waited = lines.values, startedWhileOld = starts.values.count
            // The leader's setup for the build this Mac runs arrives: the part starts.
            try macs.readopt(runtime: Self.sha256(follower.worker))
            let until = Date().addingTimeInterval(20)
            while starts.values.isEmpty, Date() < until { usleep(20_000) }
            stop.signal()
            #expect(done.wait(timeout: .now() + 30) == .success, "the service did not stop")
            #expect(startedWhileOld == 0, "the old setup's part started: \(waited)")
            #expect(waited.filter { $0 == wait }.count == 1, "\(waited)")
            #expect(!starts.values.isEmpty, "the part did not start with the new setup: \(lines.values)")
        }
    }

    private static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// `count` bytes of a seeded sequence (no two files alike, nothing the file system compresses away).
    private static func bytes(_ count: Int, seed: UInt64) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            var state = seed &* 0x9E37_79B9_7F4A_7C15
            for offset in stride(from: 0, to: raw.count - 7, by: 8) {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                raw.storeBytes(of: state, toByteOffset: offset, as: UInt64.self)
            }
        }
        return data
    }

    /// Reads the whole file through the file cache, as a copy or an earlier read leaves it.
    private static func readThroughCache(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        let chunk = 8 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16_384)
        defer { buffer.deallocate() }
        var offset: off_t = 0
        while true {
            let count = pread(fd, buffer, chunk, offset)
            if count < 0 && errno == EINTR { continue }
            try #require(count >= 0)
            if count == 0 { break }
            offset += off_t(count)
        }
    }

    /// The share of the file's pages in the file cache (`mincore`).
    private static func residentShare(_ url: URL) -> Double {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 0,
              let resident = PageCache.residentBytes(fileAt: url) else { return -1 }
        return Double(resident) / Double(size)
    }
}
