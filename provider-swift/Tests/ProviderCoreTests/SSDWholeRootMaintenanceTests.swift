// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("SSD prefix cache: unloaded whole-root maintenance", .serialized)
struct SSDWholeRootMaintenanceTests {
    private func writeOwnedFile(
        root: URL,
        modelKey: String,
        tagHex: String,
        modifiedAt: Int64,
        payloadBytes: Int = 128
    ) throws -> URL {
        let modelRoot = root.appendingPathComponent(modelKey, isDirectory: true)
        try SSDBlockStore.prepareModelRoot(
            dedicatedRoot: root,
            modelRoot: modelRoot)
        let url = SSDBlockStore.fileURL(root: modelRoot, tag16Hex: tagHex)
        let chunk = Data(repeating: 7, count: payloadBytes)
        let metadata = SSDBlockMetadata(
            lookupTag: String(repeating: "ab", count: 32),
            weightHash: "weight",
            layoutEpoch: "layout",
            blockSize: 8,
            layerCount: 1,
            chunks: [.init(
                layerIndex: 0,
                tensor: 0,
                shape: [1, 1, 1, 1],
                dtype: "float16")],
            chunkPlaintextSizes: [chunk.count],
            createdAt: modifiedAt)
        try SSDBlockStore.write(
            to: url,
            metadata: metadata,
            chunks: [chunk],
            kekKey: SymmetricKey(size: .bits256))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: TimeInterval(modifiedAt))],
            ofItemAtPath: url.path)
        return url
    }

    private func writeOwnedTemp(
        root: URL,
        modelKey: String,
        tagHex: String,
        uuid: UUID,
        modifiedAt: Int64,
        payloadBytes: Int
    ) throws -> URL {
        let destination = SSDBlockStore.fileURL(
            root: root.appendingPathComponent(modelKey, isDirectory: true),
            tag16Hex: tagHex)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let url = SSDBlockStore.temporaryFileURL(for: destination, uuid: uuid)
        try Data(repeating: 9, count: payloadBytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: TimeInterval(modifiedAt))],
            ofItemAtPath: url.path)
        return url
    }

    @Test("startup sweep expires files in unloaded model directories")
    func unloadedTTL() throws {
        let root = tempDir("whole-root-ttl")
        defer { try? FileManager.default.removeItem(at: root) }
        let expired = try writeOwnedFile(
            root: root,
            modelKey: "aaaaaaaaaaaa",
            tagHex: "aa00112233445566778899aabbccddee",
            modifiedAt: 1_000)
        let fresh = try writeOwnedFile(
            root: root,
            modelKey: "bbbbbbbbbbbb",
            tagHex: "bb00112233445566778899aabbccddee",
            modifiedAt: 1_950)

        let result = SSDWholeRootMaintainer.shared.maintain(
            root: root,
            ttlSeconds: 900,
            nowSeconds: 2_000,
            budgetBytes: Int.max)
        #expect(result.ttlExpired == 1)
        #expect(!FileManager.default.fileExists(atPath: expired.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test("20 GiB-style budget is global across unloaded model directories")
    func globalBudget() throws {
        let root = tempDir("whole-root-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try writeOwnedFile(
            root: root,
            modelKey: "111111111111",
            tagHex: "1100112233445566778899aabbccddee",
            modifiedAt: 1_000,
            payloadBytes: 256)
        let fresh = try writeOwnedFile(
            root: root,
            modelKey: "222222222222",
            tagHex: "2200112233445566778899aabbccddee",
            modifiedAt: 2_000,
            payloadBytes: 256)
        let freshBytes = try fresh.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0

        let result = SSDWholeRootMaintainer.shared.maintain(
            root: root,
            ttlSeconds: 10_000,
            nowSeconds: 2_100,
            budgetBytes: freshBytes)
        #expect(result.budgetEvicted == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(result.bytesAfter <= freshBytes)
    }

    @Test("whole-root eviction durably rotates the model epoch before unlink")
    func evictionRotatesEpoch() throws {
        let root = tempDir("whole-root-epoch")
        defer { try? FileManager.default.removeItem(at: root) }
        let modelKey = "333333333333"
        let modelRoot = root.appendingPathComponent(modelKey, isDirectory: true)
        let block = try writeOwnedFile(
            root: root,
            modelKey: modelKey,
            tagHex: "3300112233445566778899aabbccddee",
            modifiedAt: 1_000,
            payloadBytes: 256)
        let binding = SSDCacheEpochStore.Binding(
            modelId: "model",
            modelAggregateHash: String(repeating: "a", count: 64),
            promptContractId: String(repeating: "b", count: 64),
            blockHashVersion: CBv2BlockHasher.version,
            blockSize: 256,
            layoutEpoch: "layout",
            keyFingerprint: String(repeating: "c", count: 64))
        let active = try SSDCacheEpochStore(root: modelRoot, binding: binding)
        let original = try #require(active.current)

        let result = SSDWholeRootMaintainer.shared.maintain(
            root: root,
            ttlSeconds: 10_000,
            nowSeconds: 2_000,
            budgetBytes: 0)
        #expect(result.budgetEvicted == 1)
        #expect(!FileManager.default.fileExists(atPath: block.path))
        #expect(active.current == nil, "the previously advertised epoch must be disabled")

        let reopened = try SSDCacheEpochStore(root: modelRoot, binding: binding)
        let rotated = try #require(reopened.current)
        #expect(rotated != original)
    }

    @Test("whole-root eviction keeps an active cache on the rotated epoch")
    func activeWholeRootEvictionKeepsCapabilityReady() async throws {
        let root = tempDir("whole-root-active-epoch")
        defer { try? FileManager.default.removeItem(at: root) }
        let modelRoot = root.appendingPathComponent("444444444444", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelRoot, withIntermediateDirectories: true)
        let binding = SSDCacheEpochStore.Binding(
            modelId: "test-model",
            modelAggregateHash: "test-weight-hash",
            promptContractId: "test-prompt-contract",
            blockHashVersion: CBv2BlockHasher.version,
            blockSize: fixtureBlockSize,
            layoutEpoch: SSDBlockStore.layoutEpoch(
                blockSize: fixtureBlockSize, layerKinds: fixtureLayerKinds),
            keyFingerprint: String(repeating: "d", count: 64))
        let epochStore = try SSDCacheEpochStore(root: modelRoot, binding: binding)
        let cache = makeCache(
            dir: modelRoot,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            diskBudget: .shared,
            epochStore: epochStore)
        defer { cache.close() }
        cache.startBackgroundTasks(sweepIntervalSeconds: 3_600)

        var advertised: PrefixCacheV2Capability?
        for _ in 0 ..< 100 {
            advertised = cache.prefixCacheV2Capability()
            if advertised != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let original = try #require(advertised)
        let tokens = Array(0 ..< 64)
        cache.donate(
            tokens: tokens,
            snapshots: fixtureSnapshots(tokenCount: tokens.count),
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)
        #expect(await waitForIndexCount(cache, atLeast: 1))
        await cache.waitForWritesForTesting()

        let result = SSDWholeRootMaintainer.shared.maintain(
            root: root,
            ttlSeconds: 10_000,
            nowSeconds: 10_000,
            budgetBytes: 0)
        #expect(result.budgetEvicted > 0)
        SSDDiskBudget.shared.reconcileAll()

        let rotated = try #require(cache.prefixCacheV2Capability())
        #expect(rotated.cacheEpoch != original.cacheEpoch)
        #expect(cache.index.count == 0)
    }

    @Test("young temp bytes consume global budget without making the active temp evictable")
    func youngTempBudgetAccounting() throws {
        let root = tempDir("whole-root-temp-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let completed = try writeOwnedFile(
            root: root,
            modelKey: "111111111111",
            tagHex: "1100112233445566778899aabbccddee",
            modifiedAt: 1_000,
            payloadBytes: 256)
        let now: Int64 = 10_000
        let temp = try writeOwnedTemp(
            root: root,
            modelKey: "222222222222",
            tagHex: "2200112233445566778899aabbccddee",
            uuid: #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")),
            modifiedAt: now - SSDBlockStore.crashTempTTLSeconds + 1,
            payloadBytes: 257)
        let tempBytes = try #require(
            temp.resourceValues(forKeys: [.fileSizeKey]).fileSize)

        let result = SSDWholeRootMaintainer.shared.maintain(
            root: root,
            ttlSeconds: 0,
            nowSeconds: now,
            budgetBytes: tempBytes)
        #expect(result.budgetEvicted == 1)
        #expect(!FileManager.default.fileExists(atPath: completed.path))
        #expect(FileManager.default.fileExists(atPath: temp.path))
        #expect(result.bytesAfter == tempBytes)

        let belowTempBudget = SSDWholeRootMaintainer.shared.maintain(
            root: root,
            ttlSeconds: 0,
            nowSeconds: now,
            budgetBytes: tempBytes - 1)
        #expect(belowTempBudget.budgetEvicted == 0)
        #expect(belowTempBudget.bytesAfter == tempBytes)
        #expect(FileManager.default.fileExists(atPath: temp.path))
    }

    @Test("malformed exact-looking files remain untouched without DBK3 ownership proof")
    func malformedLookalikePreserved() throws {
        let root = tempDir("whole-root-lookalike")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("abcdefabcdef", isDirectory: true)
        let fanout = model.appendingPathComponent("ab", isDirectory: true)
        try FileManager.default.createDirectory(at: fanout, withIntermediateDirectories: true)
        let lookalike = fanout.appendingPathComponent(
            "ab00112233445566778899aabbccddee.dbk3")
        try Data("not-a-darkbloom-block".utf8).write(to: lookalike)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: lookalike.path)

        let result = SSDWholeRootMaintainer.shared.maintain(
            root: root,
            ttlSeconds: 1,
            nowSeconds: 10_000,
            budgetBytes: 0)
        #expect(result.filesSeen == 0)
        #expect(FileManager.default.fileExists(atPath: lookalike.path))
    }

    @Test("maintenance rejects roots reached through a symlinked ancestor")
    func symlinkedRootIsNeverTraversed() throws {
        let container = tempDir("whole-root-symlink-container")
        let root = container.appendingPathComponent("kv3", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stale = try writeOwnedTemp(
            root: root,
            modelKey: "abcdefabcdef",
            tagHex: "ab00112233445566778899aabbccddee",
            uuid: try #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")),
            modifiedAt: 1_000,
            payloadBytes: 64)
        let alias = container.deletingLastPathComponent().appendingPathComponent(
            "ssd-prefix-root-alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: container)
        defer {
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.removeItem(at: container)
        }
        let aliasedRoot = alias.appendingPathComponent("kv3", isDirectory: true)

        let result = SSDWholeRootMaintainer.shared.maintain(
            root: aliasedRoot,
            ttlSeconds: 1,
            nowSeconds: 10_000,
            budgetBytes: 0)
        #expect(result == SSDWholeRootMaintainer.Result())
        #expect(SSDBlockStore.sweepStaleTempFiles(
            under: aliasedRoot.appendingPathComponent("abcdefabcdef", isDirectory: true),
            nowSeconds: 10_000) == 0)
        #expect(FileManager.default.fileExists(atPath: stale.path))
    }

    @Test("whole-root sweep preserves young and near-match temps but removes stale owned temps")
    func tempCleanupUsesAgeAndExactOwnership() throws {
        let root = tempDir("whole-root-temp-ownership")
        defer { try? FileManager.default.removeItem(at: root) }
        let now: Int64 = 10_000
        let uuid = "01234567-89AB-CDEF-0123-456789ABCDEF"
        let tag = "ab00112233445566778899aabbccddee"
        let exactName = "\(tag).dbk3.darkbloom-tmp.\(uuid)"

        func create(
            _ relativeDirectory: String,
            _ name: String,
            modifiedAt: Int64 = 0
        ) throws -> URL {
            let directory = root.appendingPathComponent(relativeDirectory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try Data("incomplete".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(modifiedAt))],
                ofItemAtPath: url.path)
            return url
        }

        let stale = try create(
            "abcdefabcdef/ab", exactName,
            modifiedAt: now - SSDBlockStore.crashTempTTLSeconds)
        let young = try create(
            "abcdefabcdef/ab",
            "\(tag).dbk3.darkbloom-tmp.31234567-89AB-CDEF-0123-456789ABCDEF",
            modifiedAt: now - SSDBlockStore.crashTempTTLSeconds + 1)
        let preserved = try [
            young,
            // UUID values differ so case-only near-matches remain distinct on
            // the default case-insensitive macOS filesystem.
            create("abcdefabcdef/ab", "\(tag).dbk3.darkbloom-tmp.11234567-89ab-cdef-0123-456789abcdef"),
            create("abcdefabcdef/ab", "\(tag).dbk3.darkbloom-tmp.21234567-89AB-cDEF-0123-456789ABCDef"),
            create("abcdefabcdef/ab", "AB00112233445566778899aabbccddee.dbk3.darkbloom-tmp.11234567-89AB-CDEF-0123-456789ABCDEF"),
            create("abcdefabcdef/ab", "\(tag).dbk3.darkbloom-tmp.not-a-uuid"),
            create("abcdefabcdef/ab", "\(tag).dbk3.darkbloom-tmp-\(uuid)"),
            create("abcdefabcdef/ab", "\(tag).dbk3.darkbloom-tmp.\(uuid).extra"),
            create("abcdefabcdef/cd", exactName),
            create("not-a-model/ab", exactName),
            create("abcdefabcdef/not-fanout", exactName),
        ]

        let result = SSDWholeRootMaintainer.shared.maintain(
            root: root,
            ttlSeconds: 0,
            nowSeconds: now,
            budgetBytes: 0)
        #expect(result.tempFilesRemoved == 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        for url in preserved {
            #expect(FileManager.default.fileExists(atPath: url.path), "preserved \(url.path)")
        }
    }

    @Test("periodic maintenance sweeps stale unloaded-model temps and can restart")
    func periodicRestartSeam() async throws {
        let root = tempDir("whole-root-periodic")
        defer {
            SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: root)
            try? FileManager.default.removeItem(at: root)
        }
        let destination = SSDBlockStore.fileURL(
            root: root.appendingPathComponent("abcdefabcdef", isDirectory: true),
            tag16Hex: "ab00112233445566778899aabbccddee")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = SSDBlockStore.temporaryFileURL(
            for: destination,
            uuid: try #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")))
        try Data("incomplete".utf8).write(to: temp)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970:
                TimeInterval(10_000 - SSDBlockStore.crashTempTTLSeconds))],
            ofItemAtPath: temp.path)

        SSDWholeRootMaintainer.shared.startPeriodicMaintenance(
            root: root,
            ttlSeconds: 900,
            intervalSeconds: 3600,
            nowSeconds: { 10_000 },
            budgetBytes: { 1 << 20 })
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline,
            FileManager.default.fileExists(atPath: temp.path)
        {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(!FileManager.default.fileExists(atPath: temp.path))
        SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: root)

        let restartedTemp = SSDBlockStore.temporaryFileURL(
            for: destination,
            uuid: try #require(UUID(uuidString: "11234567-89AB-CDEF-0123-456789ABCDEF")))
        try Data("second-incomplete".utf8).write(to: restartedTemp)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970:
                TimeInterval(10_000 - SSDBlockStore.crashTempTTLSeconds))],
            ofItemAtPath: restartedTemp.path)
        SSDWholeRootMaintainer.shared.startPeriodicMaintenance(
            root: root,
            ttlSeconds: 900,
            intervalSeconds: 3600,
            nowSeconds: { 10_000 },
            budgetBytes: { 1 << 20 })
        let restartDeadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < restartDeadline,
            FileManager.default.fileExists(atPath: restartedTemp.path)
        {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(!FileManager.default.fileExists(atPath: restartedTemp.path))
    }
}
