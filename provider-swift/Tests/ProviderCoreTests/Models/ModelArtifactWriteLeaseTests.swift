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

    @Test("foreground verification reports a busy writer without waiting for its release")
    func verificationDoesNotWaitForModelUpdate() async throws {
        let id = "test-org/verify-lease-\(UUID().uuidString)"
        let lease = try await ModelArtifactWriteLease.acquire(modelID: id)
        defer { lease.release() }
        let model = CatalogModel(id: id, s3Name: id, displayName: id, sizeGb: 1, weightHash: "test")
        let verification = Task {
            do {
                try await ModelDownloader().verifySelectedModel(model)
                return "unexpected success"
            } catch { return error.localizedDescription }
        }
        // Bound regressions: the old implementation waits forever for this
        // test's lease. Cancellation unblocks it and yields a different error.
        let timeout = Task {
            try await Task.sleep(for: .seconds(2))
            verification.cancel()
        }
        defer { timeout.cancel() }
        let message = await verification.value
        #expect(message.contains("another process"))
        #expect(message.contains("retry verification"))
        #expect(throws: (any Error).self) {
            try ModelArtifactWriteLease.acquireIfAvailable(modelID: id)
        }
    }

    @Test("a start's verification reports a held writer lease as its own error type, with the same text")
    func heldLeaseIsTyped() async throws {
        let id = "test-org/typed-lease-\(UUID().uuidString)"
        let lease = try await ModelArtifactWriteLease.acquire(modelID: id)
        defer { lease.release() }
        let model = CatalogModel(id: id, s3Name: id, displayName: id, sizeGb: 1, weightHash: "test")
        let expected = "download failed: \(id) is being downloaded, updated or verified by another process; "
            + "retry verification after it finishes"
        do {
            try await ModelDownloader().verifySelectedModel(model)
            Issue.record("verification of a held model succeeded")
        } catch let busy as SelectedModelBusy {
            #expect(busy.modelID == id)
            #expect(busy.localizedDescription == expected)
        } catch {
            Issue.record("expected SelectedModelBusy, got \(error)")
        }
        // The lease itself, and its other callers, are unchanged.
        #expect(throws: ModelCatalogError.self) { try ModelArtifactWriteLease.acquireIfAvailable(modelID: id) }
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
