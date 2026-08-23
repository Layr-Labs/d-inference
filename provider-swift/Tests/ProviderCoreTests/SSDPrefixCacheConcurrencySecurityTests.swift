// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("SSD prefix cache: concurrent filesystem security", .serialized)
struct SSDPrefixCacheConcurrencySecurityTests {

    @Test("active cache I/O rejects symlinked root, model, and fanout paths")
    func activeSymlinkIOFailsClosed() throws {
        let parent = tempDir("active-symlinks")
        defer { try? FileManager.default.removeItem(at: parent) }
        let fm = FileManager.default

        let realDedicated = parent.appendingPathComponent("real", isDirectory: true)
        let linkedDedicated = parent.appendingPathComponent("linked", isDirectory: true)
        try fm.createDirectory(at: realDedicated, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedDedicated, withDestinationURL: realDedicated)
        #expect(throws: (any Error).self) {
            try SSDBlockStore.prepareModelRoot(
                dedicatedRoot: linkedDedicated,
                modelRoot: linkedDedicated.appendingPathComponent("aaaaaaaaaaaa"))
        }

        let outsideModel = parent.appendingPathComponent("outside-model", isDirectory: true)
        try fm.createDirectory(at: outsideModel, withIntermediateDirectories: true)
        let modelLink = realDedicated.appendingPathComponent("aaaaaaaaaaaa", isDirectory: true)
        try fm.createSymbolicLink(at: modelLink, withDestinationURL: outsideModel)
        #expect(throws: (any Error).self) {
            try SSDBlockStore.prepareModelRoot(
                dedicatedRoot: realDedicated,
                modelRoot: modelLink)
        }
        try fm.removeItem(at: modelLink)

        let modelRoot = realDedicated.appendingPathComponent("bbbbbbbbbbbb", isDirectory: true)
        try SSDBlockStore.prepareModelRoot(
            dedicatedRoot: realDedicated,
            modelRoot: modelRoot)
        let outsideFanout = parent.appendingPathComponent("outside-fanout", isDirectory: true)
        try fm.createDirectory(at: outsideFanout, withIntermediateDirectories: true)
        let fanoutLink = modelRoot.appendingPathComponent("aa", isDirectory: true)
        try fm.createSymbolicLink(at: fanoutLink, withDestinationURL: outsideFanout)
        let url = SSDBlockStore.fileURL(
            root: modelRoot,
            tag16Hex: "aabbccdd00112233445566778899eeff")
        #expect(throws: (any Error).self) {
            try SSDBlockStore.write(
                to: url,
                metadata: blockMetadataFixture(sizes: [32]),
                chunks: [Data(repeating: 1, count: 32)],
                kekKey: SymmetricKey(size: .bits256))
        }
        #expect((try fm.contentsOfDirectory(atPath: outsideFanout.path)).isEmpty)

        let cache = makeCache(
            dir: modelRoot,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000))
        defer { cache.close() }
        cache.scanOnDisk()
        #expect(cache.index.count == 0)
        let scanStatus = cache.prefixCacheModelStatus(base: PrefixCacheModelStatus(
            modelId: "test-model",
            backend: .contiguous,
            replayStrategy: .direct,
            state: .pending,
            reason: .scanPending))
        #expect(scanStatus.state == .error)
        #expect(scanStatus.reason == .scanFailed)
        let escapedFile = outsideFanout.appendingPathComponent(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.dbk3")
        try Data("must-survive".utf8).write(to: escapedFile)
        cache.index.insert(
            tag16: Data(repeating: 0xaa, count: 16),
            fileBytes: 32,
            lastAccess: 0)
        cache.sweepExpiredEntries()
        #expect(cache.index.count == 0, "unsafe fanout must be dropped from the RAM index")
        #expect(cache.stats().ttlExpired == 0, "an invalid path is not a successful TTL deletion")
        #expect(fm.fileExists(atPath: escapedFile.path))
    }

    @Test("descriptor-relative root creation rejects a concurrent symlink replacement")
    func modelRootCreationRejectsRootSwap() throws {
        let parent = tempDir("root-create-swap")
        defer { try? FileManager.default.removeItem(at: parent) }
        let fm = FileManager.default
        let dedicated = parent.appendingPathComponent("cache", isDirectory: true)
        let detached = parent.appendingPathComponent("detached-cache", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        let model = dedicated.appendingPathComponent("aaaaaaaaaaaa", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) {
            try SSDBlockStore.prepareModelRoot(
                dedicatedRoot: dedicated,
                modelRoot: model,
                beforeModelCreation: {
                    try! FileManager.default.moveItem(at: dedicated, to: detached)
                    try! FileManager.default.createSymbolicLink(
                        at: dedicated,
                        withDestinationURL: outside)
                })
        }
        #expect(!fm.fileExists(
            atPath: outside.appendingPathComponent("aaaaaaaaaaaa").path))
        #expect(fm.fileExists(
            atPath: detached.appendingPathComponent("aaaaaaaaaaaa").path))
    }

    @Test("descriptor-relative active I/O cannot be redirected by a fanout symlink race")
    func activeIORenameToSymlinkRace() throws {
        struct Fixture {
            let parent: URL
            let modelRoot: URL
            let file: URL
            let outsideFile: URL
            let hook: @Sendable (SSDActiveIOOperation) -> Void
        }
        var parents: [URL] = []
        defer { for parent in parents { try? FileManager.default.removeItem(at: parent) } }
        let kek = SymmetricKey(size: .bits256)
        let tag = "aabbccdd00112233445566778899eeff"
        let originalChunk = Data(repeating: 3, count: 32)
        let outsideSentinel = Data("outside-must-remain-untouched".utf8)

        func makeFixture(_ label: String) throws -> Fixture {
            let parent = tempDir("nofollow-\(label)")
            parents.append(parent)
            let dedicated = parent.appendingPathComponent("cache", isDirectory: true)
            let modelRoot = dedicated.appendingPathComponent("aaaaaaaaaaaa", isDirectory: true)
            try SSDBlockStore.prepareModelRoot(
                dedicatedRoot: dedicated, modelRoot: modelRoot)
            let file = SSDBlockStore.fileURL(root: modelRoot, tag16Hex: tag)
            _ = try SSDBlockStore.write(
                to: file,
                metadata: blockMetadataFixture(sizes: [originalChunk.count]),
                chunks: [originalChunk],
                kekKey: kek)

            let fanout = file.deletingLastPathComponent()
            let detachedFanout = modelRoot.appendingPathComponent("detached-aa")
            let outsideFanout = parent.appendingPathComponent("outside-aa", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outsideFanout, withIntermediateDirectories: true)
            let outsideFile = outsideFanout.appendingPathComponent(file.lastPathComponent)
            try outsideSentinel.write(to: outsideFile)
            let hook: @Sendable (SSDActiveIOOperation) -> Void = { _ in
                try! FileManager.default.moveItem(at: fanout, to: detachedFanout)
                try! FileManager.default.createSymbolicLink(
                    at: fanout, withDestinationURL: outsideFanout)
            }
            return Fixture(
                parent: parent,
                modelRoot: modelRoot,
                file: file,
                outsideFile: outsideFile,
                hook: hook)
        }

        let readFixture = try makeFixture("read")
        let (readMetadata, readChunks) = try SSDBlockStore.read(
            from: readFixture.file,
            kekKey: kek,
            beforeOperation: readFixture.hook)
        #expect(readMetadata.weightHash == "w-hash")
        #expect(readChunks == [originalChunk])
        #expect(try Data(contentsOf: readFixture.outsideFile) == outsideSentinel)

        let writeFixture = try makeFixture("write")
        _ = try SSDBlockStore.write(
            to: writeFixture.file,
            metadata: blockMetadataFixture(sizes: [48]),
            chunks: [Data(repeating: 9, count: 48)],
            kekKey: kek,
            beforeOperation: writeFixture.hook)
        #expect(try Data(contentsOf: writeFixture.outsideFile) == outsideSentinel)

        let touchFixture = try makeFixture("touch")
        let outsideDate = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes(
            [.modificationDate: outsideDate],
            ofItemAtPath: touchFixture.outsideFile.path)
        SSDBlockStore.setAttributesIfSafe(
            [.modificationDate: Date(timeIntervalSince1970: 9_000)],
            at: touchFixture.file,
            under: touchFixture.modelRoot,
            beforeOperation: touchFixture.hook)
        let untouchedDate = try touchFixture.outsideFile.resourceValues(
            forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(untouchedDate == outsideDate)

        let deleteFixture = try makeFixture("delete")
        #expect(SSDBlockStore.removeItemIfSafe(
            at: deleteFixture.file,
            under: deleteFixture.modelRoot,
            beforeOperation: deleteFixture.hook))
        #expect(try Data(contentsOf: deleteFixture.outsideFile) == outsideSentinel)
    }

    @Test("reconciliation drops a symlink-replaced indexed file without following it")
    func reconciliationDropsSymlinkReplacement() throws {
        let dir = tempDir("reconcile-symlink")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = makeCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000))
        defer { cache.close() }

        let tag = Data(repeating: 0xaa, count: 16)
        let url = SSDBlockStore.fileURL(
            root: dir, tag16Hex: SSDLookupKeys.hex(tag))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let outside = dir.deletingLastPathComponent().appendingPathComponent(
            "ssd-reconcile-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside-must-survive".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: url, withDestinationURL: outside)
        cache.index.insert(tag16: tag, fileBytes: 32, lastAccess: 1)

        cache.reconcileExternalRemovals()

        #expect(cache.index.count == 0)
        #expect(try Data(contentsOf: outside) == Data("outside-must-survive".utf8))
        #expect(SSDBlockStore.indexedBlockFileStatus(at: url, under: dir) == .invalid)
    }
}
