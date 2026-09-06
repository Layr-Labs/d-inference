import CryptoKit
import Darwin
import Foundation
import Testing
@testable import ProviderCore

@Suite("Checkpoint authenticated recency coordination", .serialized)
struct SSDCheckpointRecencyCoordinationTests {
    private struct Fixture: Sendable {
        let root: URL
        let model: URL
        let file: URL
        let key = SymmetricKey(size: .bits256)
        let chunks = [Data(repeating: 0x31, count: 257), Data(repeating: 0x92, count: 4096)]
        let recency = Date(timeIntervalSince1970: 1_700_000_000)

        init(publish: Bool = true, directory: URL? = nil) throws {
            root = (directory ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath())
                .appendingPathComponent("ssd-recency-\(UUID().uuidString)")
            model = root.appendingPathComponent("0123456789ab")
            try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: model)
            file = SSDBlockStore.fileURL(root: model, tag16Hex: String(repeating: "a", count: 32))
            if publish { try write() }
        }

        func write() throws {
            let metadata = SSDBlockMetadata(
                lookupTag: String(repeating: "a", count: 64), weightHash: "weights",
                layoutEpoch: "recency-fixture", blockSize: 256, layerCount: 1,
                chunks: chunks.enumerated().map {
                    .init(layerIndex: 0, tensor: $0.offset, shape: [$0.element.count], dtype: "uint8")
                }, chunkPlaintextSizes: chunks.map(\.count), createdAt: 1)
            _ = try SSDBlockStore.writeStreaming(
                to: file, metadata: metadata, kekKey: key, maximumChunkBytes: 4096, chunk: { chunks[$0] })
            touch()
        }

        func touch() {
            SSDBlockStore.setAttributesIfSafe([.modificationDate: recency], at: file, under: model)
        }

        func read(onChunk: (Int) throws -> Void = { _ in }) throws -> SSDAuthenticatedFileIdentity {
            var identity: SSDAuthenticatedFileIdentity?
            var received = 0
            try SSDBlockStore.readStreaming(
                from: file, kekKey: key, maximumChunkBytes: 4096, maximumPlaintextBytes: 4353,
                requireEOF: true, onAuthenticatedFile: { identity = $0 },
                validateMetadata: { _ in }, consumeChunk: { index, data in
                    #expect(data == chunks[index])
                    received += 1
                    try onChunk(index)
                })
            #expect(received == chunks.count)
            let proof = try #require(identity)
            guard proof.matches(url: file) else { throw SSDAuthenticatedFileChange.changedDuringRead }
            return proof
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("reproducer: identical mtime touch changes ctime during a complete authenticated read")
    func uncoordinatedSameTimestampReproducer() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.file)
        let previous = try fixture.read()
        var firstChunks = 0
        var second: SSDAuthenticatedFileIdentity?
        #expect(throws: SSDAuthenticatedFileChange.self) {
            try fixture.read { index in
                firstChunks += 1
                if index == 0 {
                    fixture.touch()
                    second = try fixture.read()
                }
            }
        }
        #expect(firstChunks == fixture.chunks.count)
        #expect(second != nil && second != previous)
        var attributes = stat()
        #expect(lstat(fixture.file.path, &attributes) == 0)
        #expect(attributes.st_mtimespec.tv_sec == 1_700_000_000)
        #expect(attributes.st_mtimespec.tv_nsec == 0)
        #expect(try Data(contentsOf: fixture.file) == original)
    }

    @Test("queued recency touch cannot invalidate an active authenticated snapshot", arguments: [false, true])
    func coordinatedOverlappingReads(publishedBeforeAccess: Bool) async throws {
        let fixture = try Fixture(publish: publishedBeforeAccess,
                                  directory: URL(fileURLWithPath: "/tmp", isDirectory: true))
        defer { fixture.remove() }
        let coordinator = SSDCheckpointFileCoordinator()
        let coordinationURL = URL(fileURLWithPath: "/private" + fixture.file.path, isDirectory: false)
        let barrier = SSDCheckpointCoordinationTestSupport.Barrier()
        let secondTouch = SSDCheckpointCoordinationTestSupport.Barrier()
        defer { barrier.release(); secondTouch.release() }
        let firstAccess = coordinator.makeAccess(to: coordinationURL)
        let first = Task.detached {
            try await firstAccess.acquire()
            defer { firstAccess.release() }
            if !publishedBeforeAccess { try fixture.write() }
            fixture.touch()
            return try fixture.read { index in if index == 0 { try barrier.block() } }
        }
        defer { first.cancel(); barrier.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { barrier.isEntered }
        let secondAccess = coordinator.makeAccess(to: coordinationURL)
        let second = Task.detached {
            try await secondAccess.acquire()
            defer { secondAccess.release() }
            fixture.touch()
            try secondTouch.block()
            return try fixture.read()
        }
        defer { second.cancel() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil {
            coordinator.pendingCount(for: coordinationURL) == 1 || secondTouch.isEntered
        }
        #expect(coordinator.trackedFileCount == 1)
        #expect(coordinator.pendingCount(for: coordinationURL) == 1)
        #expect(!secondTouch.isEntered)
        barrier.release()
        secondTouch.release()
        let firstResult = await first.result
        let secondResult = await second.result
        let firstProof = try firstResult.get()
        let secondProof = try secondResult.get()
        #expect(firstProof != secondProof)
        #expect(secondProof.matches(url: fixture.file))
        #expect(coordinator.trackedFileCount == 0)
    }

    @Test("coordination still rejects external replacements and corrupt ciphertext")
    func authenticationIsNotRelaxed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let coordinator = SSDCheckpointFileCoordinator()
        let access = coordinator.makeAccess(to: fixture.file)
        try await access.acquire()
        defer { access.release() }
        let original = try Data(contentsOf: fixture.file)
        #expect(throws: SSDAuthenticatedFileChange.self) {
            try fixture.read { index in
                if index == 0 { try original.write(to: fixture.file, options: .atomic) }
            }
        }
        var corrupt = original
        corrupt[corrupt.count - 1] ^= 1
        try corrupt.write(to: fixture.file)
        #expect(throws: SSDBlockStoreError.self) { try fixture.read() }
    }
}
