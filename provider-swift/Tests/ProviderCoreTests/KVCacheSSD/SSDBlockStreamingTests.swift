import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

@Suite("Encrypted SSD chunk streaming")
struct SSDBlockStreamingTests {
    private struct Fixture {
        let root: URL
        let file: URL
        let key = SymmetricKey(size: .bits256)
        let chunks = [Data(repeating: 0x31, count: 257), Data(repeating: 0x92, count: 4096)]

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("ssd-stream-\(UUID().uuidString)")
            let model = root.appendingPathComponent("0123456789ab")
            try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: model)
            file = SSDBlockStore.fileURL(root: model, tag16Hex: String(repeating: "a", count: 32))
        }

        var metadata: SSDBlockMetadata {
            SSDBlockMetadata(
                lookupTag: String(repeating: "a", count: 64), weightHash: "weights",
                layoutEpoch: "stream-fixture", blockSize: 256, layerCount: 1,
                chunks: chunks.enumerated().map {
                    .init(layerIndex: 0, tensor: $0.offset, shape: [$0.element.count], dtype: "uint8")
                }, chunkPlaintextSizes: chunks.map(\.count), createdAt: 1)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
        func write() throws {
            _ = try SSDBlockStore.writeStreaming(
                to: file, metadata: metadata, kekKey: key, maximumChunkBytes: 4096,
                chunk: { chunks[$0] })
        }
    }

    @Test("stream and aggregate wrappers read each other's unchanged DBK3 format")
    func wireCompatibility() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write()
        let (metadata, chunks) = try SSDBlockStore.read(from: f.file, kekKey: f.key)
        #expect(metadata == f.metadata)
        #expect(chunks == f.chunks)
        _ = try SSDBlockStore.write(to: f.file, metadata: f.metadata, chunks: f.chunks, kekKey: f.key)
        var observed: [Data] = []
        let streamed = try SSDBlockStore.readStreaming(
            from: f.file, kekKey: f.key, maximumChunkBytes: 4096, maximumPlaintextBytes: 4353,
            validateMetadata: { #expect($0 == f.metadata) },
            consumeChunk: { index, data in
                #expect(index == observed.count)
                observed.append(data)
            })
        #expect(streamed == metadata)
        #expect(observed == f.chunks)
    }

    @Test("size and identity gates run before any payload reaches the sink")
    func rejectBeforePayload() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write()
        for (chunkLimit, totalLimit) in [(4095, 4353), (4096, 4352)] {
            var invoked = false
            #expect(throws: (any Error).self) {
                try SSDBlockStore.readStreaming(
                    from: f.file, kekKey: f.key, maximumChunkBytes: chunkLimit,
                    maximumPlaintextBytes: totalLimit,
                    validateMetadata: { _ in invoked = true }, consumeChunk: { _, _ in invoked = true })
            }
            #expect(!invoked)
        }
        var received = 0
        #expect(throws: CancellationError.self) {
            try SSDBlockStore.readStreaming(
                from: f.file, kekKey: f.key, maximumChunkBytes: 4096, maximumPlaintextBytes: 4353,
                validateMetadata: { _ in throw CancellationError() }, consumeChunk: { _, _ in received += 1 })
        }
        #expect(received == 0)
    }

    @Test("wrong key never invokes even the manifest validator")
    func headerAuthenticationPrecedesAllocation() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write()
        var invoked = false
        #expect(throws: (any Error).self) {
            try SSDBlockStore.readStreaming(
                from: f.file, kekKey: SymmetricKey(size: .bits256),
                maximumChunkBytes: 4096, maximumPlaintextBytes: 4353,
                validateMetadata: { _ in invoked = true }, consumeChunk: { _, _ in invoked = true })
        }
        #expect(!invoked)
    }

    @Test("corrupt later chunk never reaches the import sink")
    func corruptChunk() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write()
        var bytes = try Data(contentsOf: f.file)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: f.file)
        var received = 0
        #expect(throws: (any Error).self) {
            try SSDBlockStore.readStreaming(
                from: f.file, kekKey: f.key, maximumChunkBytes: 4096, maximumPlaintextBytes: 4353,
                validateMetadata: { _ in }, consumeChunk: { _, _ in received += 1 })
        }
        #expect(received == 1)
    }

    @Test("cancelled write preserves prior committed file and removes partial temp")
    func partialWriteNeverCommits() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write()
        let original = try Data(contentsOf: f.file)
        #expect(throws: CancellationError.self) {
            try SSDBlockStore.writeStreaming(
                to: f.file, metadata: f.metadata, kekKey: f.key, maximumChunkBytes: 4096,
                chunk: { index in
                    if index == 1 { throw CancellationError() }
                    return f.chunks[index]
                })
        }
        #expect(try Data(contentsOf: f.file) == original)
        let names = try FileManager.default.contentsOfDirectory(atPath: f.file.deletingLastPathComponent().path)
        #expect(names == [f.file.lastPathComponent])
    }

    @Test("cancelled sink stops before reading the next chunk")
    func cancelRead() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write()
        var received = 0
        #expect(throws: CancellationError.self) {
            try SSDBlockStore.readStreaming(
                from: f.file, kekKey: f.key, maximumChunkBytes: 4096, maximumPlaintextBytes: 4353,
                validateMetadata: { _ in }, consumeChunk: { _, _ in
                    received += 1
                    throw CancellationError()
                })
        }
        #expect(received == 1)
    }

    @Test("complete checkpoint mode rejects trailing bytes after valid chunks")
    func rejectTrailingBytes() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write()
        let handle = try FileHandle(forWritingTo: f.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0xff]))
        try handle.close()
        #expect(throws: (any Error).self) {
            try SSDBlockStore.readStreaming(
                from: f.file, kekKey: f.key, maximumChunkBytes: 4096, maximumPlaintextBytes: 4353,
                requireEOF: true, validateMetadata: { _ in }, consumeChunk: { _, _ in })
        }
    }

    @Test("oversized unauthenticated header lengths fail before reading their payload")
    func boundedHeaderBeforeAllocation() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write()
        let valid = try Data(contentsOf: f.file)
        for target in [20, 24 + 60] {
            var bytes = valid
            bytes.replaceSubrange(target..<(target + 4), with: [0, 0, 0, 4]) // 64 MiB
            bytes = bytes.prefix(target + 4) // No giant field exists in the file.
            try bytes.write(to: f.file)
            do {
                _ = try SSDBlockStore.readStreaming(
                    from: f.file, kekKey: f.key, maximumChunkBytes: 4096, maximumPlaintextBytes: 4353,
                    maximumMetadataBytes: 1 << 20, maximumWrappedDEKBytes: 60,
                    validateMetadata: { _ in Issue.record("validator reached unauthenticated oversized header") },
                    consumeChunk: { _, _ in Issue.record("payload reached") })
                Issue.record("oversized header accepted")
            } catch SSDBlockStoreError.malformedHeader(_) { }
            catch { Issue.record("expected length rejection before read, got \(error)") }
        }
    }
    @Test("whole-root maintenance retains valid legacy DBK3 headers and skips oversized fields")
    func maintenanceUsesBoundedCompatibleHeaders() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write()
        let validBytes = try Data(contentsOf: f.file)
        let other = SSDBlockStore.fileURL(root: f.file.deletingLastPathComponent().deletingLastPathComponent(),
            tag16Hex: String(repeating: "b", count: 32))
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        var malformed = validBytes
        malformed.replaceSubrange(20..<24, with: [0, 0, 0, 4])
        try malformed.prefix(24).write(to: other)
        let result = SSDWholeRootMaintainer().maintain(root: f.root, ttlSeconds: 3600,
            nowSeconds: Int64(Date().timeIntervalSince1970), budgetBytes: 1 << 20)
        #expect(result.filesSeen == 1)
        #expect(result.bytesAfter == validBytes.count)
        #expect(FileManager.default.fileExists(atPath: f.file.path))
    }

    @Test("a concurrent recency touch is retryable, not corrupt ciphertext")
    func recencyChangeHasTypedFailure() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write()
        let original = try Data(contentsOf: f.file)
        #expect(throws: SSDAuthenticatedFileChange.self) {
            try SSDBlockStore.readStreaming(
                from: f.file, kekKey: f.key, maximumChunkBytes: 4096,
                maximumPlaintextBytes: 4353,
                onAuthenticatedFile: { _ in Issue.record("changed file proof escaped") },
                validateMetadata: { _ in }, consumeChunk: { index, _ in
                    if index == 1 {
                        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: f.file.path)
                    }
                })
        }
        #expect(try Data(contentsOf: f.file) == original)
    }

}
