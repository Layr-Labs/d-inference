// Copyright © 2026 Eigen Labs.

import Darwin
import DarkbloomClusterProtocol
import Foundation
import os
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
        URL(fileURLWithPath: CacheStorage.canonicalPath(FileManager.default.temporaryDirectory.path), isDirectory: true)
            .appendingPathComponent("pair-expiry-\(UUID().uuidString)", isDirectory: true)
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
        let idleLock = try file(root, "\(Self.plan)/in-use", age: 0)
        let noncanonical = try ["rank-1", "rank64", "rank00", "rank+1"].map {
            try file(root, "\(Self.plan)/\($0)/\(Self.record("a"))", age: 1900)
        }
        let target = ClusterPrefixRecordExpiry.Target(root: root, ttlSeconds: 1800)
        // A running rank of the live plan holds its lock shared.
        let inUse = Darwin.open(root.appendingPathComponent("\(Self.livePlan)/in-use").path, O_RDWR | O_CREAT, 0o600)
        #expect(inUse >= 0 && flock(inUse, LOCK_SH) == 0)
        #expect(ClusterPrefixRecordExpiry.sweep(target, now: Date().timeIntervalSince1970) == 1)
        #expect(!exists(expired))
        for kept in [fresh, hidden, other, misnamed, notRank, held, staging, idleLock] + noncanonical {
            #expect(exists(kept), "\(kept.path)")
        }
        // Once no rank holds it, its expired record goes too.
        Darwin.close(inUse)
        #expect(ClusterPrefixRecordExpiry.sweep(target, now: Date().timeIntervalSince1970) == 1)
        #expect(!exists(held) && exists(fresh))
    }

    @Test("the running sweep deletes a record soon after it expires")
    func runningSweepDeletesARecordAfterItsTTL() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try file(root, "\(Self.plan)/rank0/\(Self.record("a"))", age: 0)
        _ = try file(root, "\(Self.plan)/in-use", age: 0)
        let expiry = ClusterPrefixRecordExpiry()
        // Record is live on the first pass. The second pass sees it expired.
        let passes = OSAllocatedUnfairLock(initialState: 0)
        let begin = Date().timeIntervalSince1970
        expiry.start(intervalSeconds: 1, now: {
            passes.withLock { n in n += 1; return n == 1 ? begin : begin + 1_805 }
        }, target: { .init(root: root, ttlSeconds: 1_800) })
        defer { expiry.stop() }
        let deadline = ContinuousClock.now + .seconds(15)
        while exists(record), ContinuousClock.now < deadline { try await taskSleep(.milliseconds(20)) }
        #expect(!exists(record))
    }

    /// A rank holds the cache root shared for its whole life, from before it
    /// creates a plan or its lock file.
    private func holdRootShared(_ root: URL) throws -> Int32 {
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY)
        try #require(fd >= 0 && flock(fd, LOCK_SH) == 0)
        return fd
    }

    @Test("unpair keeps staging and retries when a plan lease cannot be verified")
    func unverifiedPlanPreservesStagingAndRetry() throws {
        let directory = temporaryRoot(), root = directory.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = directory.appendingPathComponent("setup", isDirectory: true)
        try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = ClusterMemberCacheControl.Store(directory: setup)
        let record = try file(root, "\(Self.plan)/rank0/\(Self.record("a"))", age: 0)
        let staged = try file(root, "staging/session/rank0/.record.tmp", age: 0)
        // While a rank shares the root, a plan without its lock file is not repaired.
        let rank = try holdRootShared(root)
        let reply = ClusterMemberCacheControl.reclaimOnUnpair(root: root, store: store)
        #expect(!reply.problems.isEmpty && store.reclaimPending && exists(staged) && exists(record))
        #expect(!exists(root.appendingPathComponent("\(Self.plan)/in-use")))
        let other = directory.appendingPathComponent("another-cache"), b = try file(other, "\(Self.plan)/rank0/\(Self.record("b"))", age: 0)
        _ = try file(other, "\(Self.plan)/in-use", age: 0)
        let bStage = try file(other, "staging/session/rank0/.record.tmp", age: 0)
        #expect(ClusterMemberCacheControl.finishPendingReclaim(root: other, store: store)?.needsRetry == true)
        #expect(store.reclaimPending && exists(b) && exists(bStage) && exists(staged))
        let lease = root.appendingPathComponent("\(Self.plan)/in-use")
        try FileManager.default.createSymbolicLink(at: lease, withDestinationURL: record)
        #expect(ClusterMemberCacheControl.finishPendingReclaim(root: root, store: store)?.needsRetry == true)
        #expect(store.reclaimPending && exists(staged) && exists(record))
        try FileManager.default.removeItem(at: lease)
        try Data().write(to: lease)
        #expect(ClusterMemberCacheControl.finishPendingReclaim(root: root, store: store)?.needsRetry == true)
        #expect(exists(staged) && !exists(record))
        Darwin.close(rank)
        let done = try #require(ClusterMemberCacheControl.finishPendingReclaim(root: root, store: store))
        #expect(done.rootRemoved && !done.needsRetry && !store.reclaimPending && !exists(staged))
        #expect(exists(b) && exists(bStage))
    }

    @Test("a plan that lost its lock file is repaired and cleaned once no rank shares the root",
          arguments: [false, true])
    func planWithoutLockIsRepairedWhenRootIsIdle(rankRunning: Bool) throws {
        let directory = temporaryRoot(), root = directory.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = directory.appendingPathComponent("setup", isDirectory: true)
        try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = ClusterMemberCacheControl.Store(directory: setup)
        // An earlier build's interrupted whole-plan removal: records, no `in-use`.
        let record = try file(root, "\(Self.plan)/rank0/\(Self.record("a"))", age: 2_400)
        let stamp = root.appendingPathComponent("\(Self.plan)/rank0/\(ClusterPrefixRecordDirectory.ttlFile)")
        try Data("600\n".utf8).write(to: stamp)
        let staged = try file(root, "staging/session/rank0/.record.tmp", age: 0)
        let rank = rankRunning ? try holdRootShared(root) : -1
        defer { if rank >= 0 { Darwin.close(rank) } }
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY)
        try #require(fd >= 0)
        let removed = ClusterPrefixRecordExpiry.sweep(openRoot: fd, localTTL: 1_200, now: Date().timeIntervalSince1970)
        Darwin.close(fd)
        #expect(removed == (rankRunning ? 0 : 1) && exists(record) == rankRunning)
        _ = try file(root, "\(Self.plan)/rank1/\(Self.record("b"))", age: 0)
        if !rankRunning { try FileManager.default.removeItem(at: root.appendingPathComponent("\(Self.plan)/in-use")) }
        let reply = ClusterMemberCacheControl.reclaimOnUnpair(root: root, store: store)
        if rankRunning {
            #expect(!reply.problems.isEmpty && store.reclaimPending && exists(staged) && exists(record))
        } else {
            #expect(reply.problems.isEmpty && reply.removedPlans == 1 && reply.rootRemoved, "\(reply.problems)")
            #expect(!store.reclaimPending && !exists(staged) && !exists(root))
        }
    }

    @Test("a stamp an interrupted write left empty or malformed applies this Mac's TTL",
          arguments: ["", "abc\n", "0\n"])
    func malformedStampUsesLocalTTL(stamp: String) throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try file(root, "\(Self.plan)/rank0/\(Self.record("a"))", age: 1_900)
        let fresh = try file(root, "\(Self.plan)/rank0/\(Self.record("b"))", age: 600)
        _ = try file(root, "\(Self.plan)/in-use", age: 0)
        try Data(stamp.utf8).write(to: root.appendingPathComponent("\(Self.plan)/rank0/\(ClusterPrefixRecordDirectory.ttlFile)"))
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY)
        try #require(fd >= 0)
        defer { Darwin.close(fd) }
        #expect(ClusterPrefixRecordExpiry.sweep(openRoot: fd, localTTL: 1_200, now: Date().timeIntervalSince1970) == 1)
        #expect(!exists(record) && exists(fresh))
    }

    @Test("a detached pinned volume and a legacy marker never authorize cleanup elsewhere")
    func missingOriginalVolumeRemainsPending() throws {
        let directory = temporaryRoot(), root = directory.appendingPathComponent("detached/cache")
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = directory.appendingPathComponent("setup")
        try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = ClusterMemberCacheControl.Store(directory: setup), pin = UUID().uuidString.lowercased()
        let first = ClusterMemberCacheControl.reclaimOnUnpair(root: root, volumeUUID: pin, store: store)
        #expect(!first.problems.isEmpty && store.reclaimPending)
        #expect(first.statusLine.contains("did not finish"))
        #expect(ClusterMemberCacheControl.finishPendingReclaim(root: root, volumeUUID: pin, store: store)?.needsRetry == true)
        let file = try self.file(root, "\(Self.plan)/rank0/\(Self.record("a"))", age: 0)
        _ = try self.file(root, "\(Self.plan)/in-use", age: 0)
        #expect(ClusterMemberCacheControl.finishPendingReclaim(root: root, volumeUUID: pin, store: store)?.needsRetry == true)
        #expect(exists(file) && store.reclaimPending)
        try Data("1\n".utf8).write(to: store.pendingFile); chmod(store.pendingFile.path, 0o600)
        #expect(ClusterMemberCacheControl.finishPendingReclaim(root: root, store: store)?.needsRetry == true)
        #expect(exists(file) && store.reclaimPending)
    }

    @Test("a new unpair replaces an earlier-format, malformed or multi-link marker without acting on it",
          arguments: ["earlier format", "malformed", "two links", "interrupted publication"])
    func newUnpairReplacesUnusableMarker(kind: String) throws {
        let directory = temporaryRoot(), root = directory.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = directory.appendingPathComponent("setup", isDirectory: true)
        try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = ClusterMemberCacheControl.Store(directory: setup)
        let other = directory.appendingPathComponent("other-link"), otherBytes = Data("{}".utf8)
        let temporaryLink = setup.appendingPathComponent(".cluster-\(UUID().uuidString.lowercased()).tmp")
        switch kind {
        case "earlier format": try Data("1\n".utf8).write(to: store.pendingFile)
        case "malformed": try Data(#"{"root":"/"#.utf8).write(to: store.pendingFile)
        case "two links":
            try otherBytes.write(to: other)
            try #require(link(other.path, store.pendingFile.path) == 0)
        default:
            // An earlier build's publish stopped between link and unlink.
            try Data("1\n".utf8).write(to: store.pendingFile)
            try #require(link(store.pendingFile.path, temporaryLink.path) == 0)
        }
        chmod(store.pendingFile.path, 0o600)
        let record = try file(root, "\(Self.plan)/rank0/\(Self.record("a"))", age: 0)
        _ = try file(root, "\(Self.plan)/in-use", age: 0)
        // A retry never takes the unusable marker as an intent.
        #expect(ClusterMemberCacheControl.finishPendingReclaim(root: root, store: store)?.needsRetry == true)
        #expect(exists(record) && store.reclaimPending)
        if kind == "interrupted publication" {
            // The retry drops only the stray same-inode link; the marker's bytes stay.
            let kept = try Data(contentsOf: store.pendingFile)
            #expect(!exists(temporaryLink) && kept == Data("1\n".utf8))
        }
        let reply = ClusterMemberCacheControl.reclaimOnUnpair(root: root, store: store)
        #expect(reply.problems.isEmpty && reply.rootRemoved && reply.removedPlans == 1, "\(reply.problems)")
        #expect(!exists(record) && !store.reclaimPending && !exists(temporaryLink))
        if kind == "two links" { #expect(try Data(contentsOf: other) == otherBytes) }
    }

    @Test("a retry after intent rename binds the first returned root before trying its held plan")
    func interruptedPublicationBindsRootOnReturn() throws {
        let directory = temporaryRoot(), root = directory.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = directory.appendingPathComponent("setup", isDirectory: true)
        try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let volume = try CacheVolume.inspect(directory: directory.path).uuid
        let marker = ClusterMemberCacheControl.reclaimPendingFileName
        let intent = try JSONEncoder().encode(["root": root.standardizedFileURL.path, "volume": volume])
        // Stop after the namespace operation, before the caller's sync/readback
        // or any cache access. A fresh store must be able to read this marker.
        do {
            let parent = try ClusterConfigurationFiles.directory(setup, privateMode: true)
            defer { Darwin.close(parent.descriptor) }
            try ClusterConfigurationFiles.renamePrivateRecord(intent, replacing: nil, parent: parent, name: marker, maximum: 8192)
            var entry = stat()
            #expect(fstatat(parent.descriptor, marker, &entry, AT_SYMLINK_NOFOLLOW) == 0 && entry.st_nlink == 1)
            #expect(throws: (any Error).self) {
                try ClusterConfigurationFiles.renamePrivateRecord(Data("other".utf8), replacing: nil,
                                                                   parent: parent, name: marker, maximum: 8192)
            }
        }
        let store = ClusterMemberCacheControl.Store(directory: setup)
        let a = try file(root, "\(Self.plan)/rank0/\(Self.record("a"))", age: 0)
        let lock = try file(root, "\(Self.plan)/in-use", age: 0)
        let fd = Darwin.open(lock.path, O_RDONLY)
        try #require(fd >= 0)
        defer { Darwin.close(fd) }
        try #require(flock(fd, LOCK_SH) == 0)
        let seen = try #require(ClusterPrefixPlanReclaim.identityForRoot(root))
        #expect(seen.volume == volume && seen.inode != nil)
        let firstPass = try #require(ClusterMemberCacheControl.finishPendingReclaim(root: root, volumeUUID: volume, store: store))
        #expect(firstPass.keptLive == 1, "\(firstPass.problems)")
        let firstBound = try Data(contentsOf: store.pendingFile)
        #expect(firstBound != intent && exists(a))
        let moved = directory.appendingPathComponent("root-a")
        try FileManager.default.moveItem(at: root, to: moved)
        let b = try file(root, "\(Self.plan)/rank0/\(Self.record("b"))", age: 0)
        _ = try file(root, "\(Self.plan)/in-use", age: 0)
        let staging = try file(root, "staging/session/rank0/.record.tmp", age: 0)
        #expect(ClusterMemberCacheControl.finishPendingReclaim(root: root, volumeUUID: volume, store: store)?.needsRetry == true)
        #expect(exists(b) && exists(staging) && store.reclaimPending)
        #expect(try Data(contentsOf: store.pendingFile) == firstBound)
        try FileManager.default.moveItem(at: root, to: directory.appendingPathComponent("root-b"))
        try FileManager.default.moveItem(at: moved, to: root)
        _ = flock(fd, LOCK_UN)
        #expect(ClusterMemberCacheControl.finishPendingReclaim(root: root, volumeUUID: volume, store: store)?.rootRemoved == true)
        #expect(!store.reclaimPending)
    }

    @Test("maintenance uses the saved volume and a rank's last applied duration")
    func pinnedSelectionAndDuration() throws {
        let environment = ["DARKBLOOM_PREFIX_CACHE_SSD_TTL_SECONDS": "1200"]
        let directory = temporaryRoot()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let volume = try CacheVolume.inspect(directory: directory.path)
        func pinned(uuid: String) throws -> ClusterPrefixRecordExpiry.Target? {
            let file = directory.appendingPathComponent("provider-\(uuid.prefix(8)).toml")
            try Data("[cache]\ndirectory = \"\(directory.path)\"\nvolume_uuid = \"\(uuid)\"\n".utf8).write(to: file)
            chmod(file.path, 0o600)
            _ = try ClusterPrefixCacheSettings.savedCacheSettings(providerConfiguration: file)
            return ClusterPrefixRecordExpiry.target(environment: environment, providerConfiguration: file)
        }
        let selected = try #require(try pinned(uuid: volume.uuid))
        #expect(selected.root.path.hasPrefix(directory.path + "/") && selected.root.lastPathComponent == "cluster-prefix-v1")
        let record = try file(selected.root, "\(Self.plan)/rank0/\(Self.record("a"))", age: 900)
        _ = try file(selected.root, "\(Self.plan)/in-use", age: 0)
        let stamp = record.deletingLastPathComponent().appendingPathComponent("expiry-ttl")
        try Data("600\n".utf8).write(to: stamp)
        let wrong = try #require(try pinned(uuid: "00000000-0000-0000-0000-000000000000"))
        #expect(ClusterPrefixRecordExpiry.sweep(wrong, now: Date().timeIntervalSince1970) == 0 && exists(record))
        let fd = try #require(ClusterPrefixRecordExpiry.openRoot(selected))
        defer { Darwin.close(fd) }
        let moved = selected.root.appendingPathExtension("old")
        try FileManager.default.moveItem(at: selected.root, to: moved)
        let replacement = try file(selected.root, "\(Self.plan)/rank0/\(Self.record("a"))", age: 2400)
        _ = try file(selected.root, "\(Self.plan)/in-use", age: 0)
        #expect(ClusterPrefixRecordExpiry.sweep(openRoot: fd, localTTL: selected.ttlSeconds, now: Date().timeIntervalSince1970) == 1)
        #expect(exists(replacement) && !exists(moved.appendingPathComponent("\(Self.plan)/rank0/\(Self.record("a"))")))
        let invalid = directory.appendingPathComponent("bad.toml")
        try Data([0xff]).write(to: invalid); chmod(invalid.path, 0o600)
        #expect(ClusterPrefixRecordExpiry.target(environment: environment, providerConfiguration: invalid) == nil)
    }
}
