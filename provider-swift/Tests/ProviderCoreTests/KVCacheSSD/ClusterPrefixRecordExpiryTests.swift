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

    private func file(_ root: URL, _ relative: String,
                      age: TimeInterval) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
        return url
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test("a pass deletes only expired records of plans no rank holds")
    func onePassDeletesExpiredRecordsOfIdlePlans() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pair-expiry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let expired = try file(root, "\(Self.plan)/rank0/a.dbpx", age: 1_900)
        let fresh = try file(root, "\(Self.plan)/rank1/b.dbpx", age: 60)
        let hidden = try file(root, "\(Self.plan)/rank0/.c.dbpx", age: 1_900)
        let other = try file(root, "\(Self.plan)/rank0/key-check", age: 1_900)
        let held = try file(root, "\(Self.livePlan)/rank0/d.dbpx", age: 1_900)
        let staging = try file(root, "staging/epoch/rank0/e.dbpx", age: 1_900)
        // A running rank of the live plan holds its lock shared.
        let inUse = Darwin.open(root.appendingPathComponent("\(Self.livePlan)/in-use").path, O_RDWR | O_CREAT, 0o600)
        #expect(inUse >= 0 && flock(inUse, LOCK_SH) == 0)
        #expect(ClusterPrefixRecordExpiry.sweep(root: root, ttlSeconds: 1_800, now: Date().timeIntervalSince1970) == 1)
        #expect(!exists(expired))
        #expect(exists(fresh) && exists(hidden) && exists(other) && exists(held) && exists(staging))
        // Once no rank holds it, its expired record goes too.
        Darwin.close(inUse)
        #expect(ClusterPrefixRecordExpiry.sweep(root: root, ttlSeconds: 1_800, now: Date().timeIntervalSince1970) == 1)
        #expect(!exists(held) && exists(fresh))
    }

    @Test("the running sweep deletes a record soon after it expires")
    func runningSweepDeletesARecordAfterItsTTL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pair-expiry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try file(root, "\(Self.plan)/rank0/a.dbpx", age: 0)
        let expiry = ClusterPrefixRecordExpiry()
        // The record is live at the first pass and expired from half a second on: a later pass deletes it.
        let begin = Date()
        expiry.start(root: root, ttlSeconds: 1_800, intervalSeconds: 1, now: {
            Date().timeIntervalSince1970 + (Date().timeIntervalSince(begin) > 0.5 ? 1_805 : 0)
        })
        defer { expiry.stop() }
        let deadline = ContinuousClock.now + .seconds(15)
        while exists(record), ContinuousClock.now < deadline { try await taskSleep(.milliseconds(20)) }
        #expect(!exists(record))
    }
}
