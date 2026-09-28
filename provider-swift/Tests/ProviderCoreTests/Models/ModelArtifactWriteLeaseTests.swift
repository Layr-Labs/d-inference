import Foundation
import Testing
@testable import ProviderCore

@Suite("Model artifact writer lease")
struct ModelArtifactWriteLeaseTests {
    @Test("model removal refuses an active writer and succeeds after its lease ends")
    func removalUsesWriterLease() async throws {
        let id = "test-org/remove-lease-\(UUID().uuidString)"
        let directory = ModelDownloader.cacheModelDirectory(for: id)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = try await ModelArtifactWriteLease.acquire(modelID: id)
        defer { lease.release() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = directory.appendingPathComponent("download-in-progress")
        try Data("owned by writer".utf8).write(to: payload)
        #expect(throws: (any Error).self) { try ModelDownloader.remove(modelID: id) }
        #expect(try Data(contentsOf: payload) == Data("owned by writer".utf8))
        lease.release()
        #expect(try ModelDownloader.remove(modelID: id))
        #expect(try !ModelDownloader.remove(modelID: id))
    }

    @Test("recreating the model directory cannot create a second writer lock")
    func lockSurvivesModelDirectoryReplacement() async throws {
        let id = "test-org/replace-lease-\(UUID().uuidString)"
        let directory = ModelDownloader.cacheModelDirectory(for: id)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = try await ModelArtifactWriteLease.acquire(modelID: id)
        defer { lease.release() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Reproduce the old remove/recreate race even if a tool bypasses the
        // downloader's guarded remove API. The held lock inode must survive.
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try ModelArtifactWriteLease.acquireIfAvailable(modelID: id) }
        lease.release()
        let nextWriter = try ModelArtifactWriteLease.acquireIfAvailable(modelID: id)
        nextWriter.release()
    }
}
