// Copyright © 2026 Eigen Labs.

import Darwin
import Foundation
import Testing
@testable import ProviderCore

/// A pair's records past the TTL are deleted while the provider runs, under
/// every plan folder no running rank holds, and nothing else is touched.
@Suite("Pair prefix record expiry")
struct ClusterPrefixRecordExpiryTests {
    private static let plan = "v1-" + String(repeating: "a", count: 24)
    private static let livePlan = "v1-" + String(repeating: "b", count: 24)

    private static func record(_ hex: Character) -> String { String(repeating: hex, count: 32) + ".dbpx" }

    private func file(_ root: URL, _ relative: String, age: TimeInterval) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
        return url
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pair-expiry-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
    }

    @Test("a pass deletes only expired records of plans no rank holds")
    func onePassDeletesExpiredRecordsOfIdlePlans() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let expired = try file(root, "\(Self.plan)/rank0/\(Self.record("a"))", age: 1_900)
        let fresh = try file(root, "\(Self.plan)/rank1/\(Self.record("b"))", age: 60)
        let hidden = try file(root, "\(Self.plan)/rank0/.\(Self.record("c"))", age: 1_900)
        let other = try file(root, "\(Self.plan)/rank0/key-check", age: 1_900)
        let misnamed = try file(root, "\(Self.plan)/rank0/a.dbpx", age: 1_900)
        let notRank = try file(root, "\(Self.plan)/ranks/\(Self.record("d"))", age: 1_900)
        let held = try file(root, "\(Self.livePlan)/rank0/\(Self.record("e"))", age: 1_900)
        let staging = try file(root, "staging/epoch/rank0/\(Self.record("f"))", age: 1_900)
        // A running rank of the live plan holds its lock shared.
        let inUse = Darwin.open(root.appendingPathComponent("\(Self.livePlan)/in-use").path, O_RDWR | O_CREAT, 0o600)
        #expect(inUse >= 0 && flock(inUse, LOCK_SH) == 0)
        #expect(ClusterPrefixRecordExpiry.sweep(root: root, ttlSeconds: 1_800, now: Date().timeIntervalSince1970) == 1)
        #expect(!exists(expired))
        for kept in [fresh, hidden, other, misnamed, notRank, held, staging] { #expect(exists(kept), "\(kept.path)") }
        // Once no rank holds it, its expired record goes too.
        Darwin.close(inUse)
        #expect(ClusterPrefixRecordExpiry.sweep(root: root, ttlSeconds: 1_800, now: Date().timeIntervalSince1970) == 1)
        #expect(!exists(held) && exists(fresh))
    }

    @Test("the running sweep deletes a record soon after it expires")
    func runningSweepDeletesARecordAfterItsTTL() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try file(root, "\(Self.plan)/rank0/\(Self.record("a"))", age: 0)
        let expiry = ClusterPrefixRecordExpiry()
        // The record is live at the first pass and expired from half a second on: a later pass deletes it.
        let begin = Date()
        expiry.start(intervalSeconds: 1, now: {
            Date().timeIntervalSince1970 + (Date().timeIntervalSince(begin) > 0.5 ? 1_805 : 0)
        }, target: { (root, 1_800) })
        defer { expiry.stop() }
        let deadline = ContinuousClock.now + .seconds(15)
        while exists(record), ContinuousClock.now < deadline { try await taskSleep(.milliseconds(20)) }
        #expect(!exists(record))
    }

    @Test("the pass sweeps the ranks' root and TTL: the saved selection, a leader's shorter TTL")
    func targetIsTheRanksRootAndTTL() throws {
        let environment = ["DARKBLOOM_PREFIX_CACHE_SSD_TTL_SECONDS": "1200"]
        let own = try #require(ClusterPrefixRecordExpiry.target(environment: environment, providerConfiguration: nil,
                                                                leaderChoices: { $0 }))
        #expect(own.root == ClusterPrefixCacheSettings.product(cacheSettings: CacheSettings(), environment: environment,
                                                               freeBytes: { _ in nil }).root)
        #expect(own.ttlSeconds == 1_200)
        func led(_ seconds: Int) -> ClusterPrefixRecordExpiry.Target? {
            ClusterPrefixRecordExpiry.target(environment: environment, providerConfiguration: nil,
                                             leaderChoices: { var value = $0; value.ttlSeconds = seconds; return value })
        }
        #expect(led(600)?.ttlSeconds == 600)
        #expect(led(1_800)?.ttlSeconds == 1_200, "never longer than this Mac's own")

        // The saved selection, not this process's: a pinned directory on its saved volume is swept, a changed one not.
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".pair-expiry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let volume = try CacheVolume.inspect(directory: directory.path)
        func pinned(uuid: String) throws -> ClusterPrefixRecordExpiry.Target? {
            let file = directory.appendingPathComponent("provider-\(uuid.prefix(8)).toml")
            try Data("[cache]\ndirectory = \"\(directory.path)\"\nvolume_uuid = \"\(uuid)\"\n".utf8).write(to: file)
            chmod(file.path, 0o600)
            return ClusterPrefixRecordExpiry.target(environment: environment, providerConfiguration: file, leaderChoices: { $0 })
        }
        let selected = try #require(try pinned(uuid: volume.uuid))
        #expect(selected.root.path.hasPrefix(directory.path + "/") && selected.root.lastPathComponent == "cluster-prefix-v1")
        #expect(try pinned(uuid: "00000000-0000-0000-0000-000000000000") == nil)
    }
}
