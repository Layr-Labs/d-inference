import Foundation
import Testing
@testable import ProviderCore

private actor RevisionPreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private final class RevisionPreparationDrainRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.withLock { count += 1 } }
    var drains: Int { lock.withLock { count } }
}

@Suite("Model revision protected preparation", .serialized)
struct ModelRevisionPreparationTests {
    private func manifest(_ fixture: RevisionActivationFixture) throws -> ModelManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ModelManifest.self,
            from: Data(contentsOf: fixture.newDirectory.appendingPathComponent(".darkbloom-manifest.json")))
    }

    private func waitForGate(_ gate: RevisionPreparationGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await gate.entered), .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await gate.entered)
    }

    @Test("a writer in the prefetch ownership gap cannot make the provider drain unusable snapshots",
        arguments: ["remove-cache", "remove-old", "corrupt-target", "corrupt-old"])
    func changedSnapshotsNeverBeginDrain(mutation: String) async throws {
        let f = try await RevisionActivationFixture.make()
        defer { f.clean() }
        let manifest = try manifest(f)
        #expect(ModelDownloader.verifiedRevisionExists(at: f.newDirectory, manifest: manifest))
        await f.loop.revisionTestBusy(f.id, busy: true)
        let gate = RevisionPreparationGate()
        let recorder = RevisionPreparationDrainRecorder()
        // Control the real ownership gap: completed prefetch has returned, but
        // catalog prewarm has not yet allowed final preparation to take a lease.
        let attempt = Task {
            await ModelIdleUpgrade.run(
                prepare: {
                    await gate.wait()
                    return try await f.loop.protectPreparedModelRevision(
                        f.staged.entry, directory: f.newDirectory, manifest: manifest)
                },
                beginDrain: { staged in
                    recorder.record()
                    try await f.loop.beginModelRevisionDrain(staged)
                },
                commitIfIdle: { _ in true },
                discard: { $0.lease.release() },
                finishDrain: { await f.loop.finishModelRevisionDrain($0) })
        }
        defer { attempt.cancel(); Task { await gate.release() } }
        try await waitForGate(gate)
        f.staged.lease.release()
        if mutation == "remove-cache" {
            #expect(try ModelDownloader.remove(modelID: f.id))
        } else {
            let writer = try ModelArtifactWriteLease.acquireIfAvailable(modelID: f.id)
            do {
                defer { writer.release() }
                if mutation == "remove-old" {
                    try FileManager.default.removeItem(at: f.oldDirectory)
                } else {
                    let directory = mutation == "corrupt-old" ? f.oldDirectory : f.newDirectory
                    // Same-length corruption defeats an existence/size-only check.
                    try Data("bad".utf8).write(to: directory.appendingPathComponent("model.safetensors"))
                }
            }
        }
        await gate.release()
        #expect(await attempt.value == .failed)
        #expect(recorder.drains == 0)
        #expect(await !f.loop.revisionTestDraining(f.id))
        #expect(await f.loop.revisionTestHash(f.id) == f.oldHash)
        #expect(await f.loop.isModelAdvertised(f.id))
        #expect(await f.loop.lifecycleRemaining == 1)
        // A failed protected preparation must release its lease for recovery.
        let retry = try ModelArtifactWriteLease.acquireIfAvailable(modelID: f.id)
        retry.release()
    }

    @Test("protected preparation derives fresh model metadata and retains ownership through activation")
    func validSnapshotsRetainLeaseAndFreshInfo() async throws {
        let f = try await RevisionActivationFixture.make()
        defer { f.clean() }
        let manifest = try manifest(f)
        f.staged.lease.release()
        let staged = try #require(try await f.loop.protectPreparedModelRevision(
            f.staged.entry, directory: f.newDirectory, manifest: manifest))
        defer { staged.lease.release() }
        #expect(staged.info.weightHash == f.newHash)
        #expect(staged.info.modelType == "gpt_oss")
        #expect(staged.info.sizeBytes == 3)
        #expect(staged.info.estimatedMemoryGb != f.staged.info.estimatedMemoryGb)
        #expect(staged.totalSizeBytes == manifest.totalSizeBytes)
        #expect(ModelScanner.resolveLocalPath(modelID: f.id) == f.oldDirectory)
        #expect(throws: (any Error).self) { try ModelDownloader.remove(modelID: f.id) }
        #expect(await !f.loop.revisionTestDraining(f.id))
    }

    @Test("cancellation or a newer desired selection prevents protected preparation", arguments: ["cancel", "supersede", "model-switch"])
    func invalidatedWhileAcquiringLease(change: String) async throws {
        let f = try await RevisionActivationFixture.make()
        defer { f.clean() }
        let manifest = try manifest(f)
        let attempt = Task {
            try await f.loop.protectPreparedModelRevision(
                f.staged.entry, directory: f.newDirectory, manifest: manifest)
        }
        if change == "cancel" {
            attempt.cancel()
        } else if change == "supersede" {
            await f.loop.revisionTestSetDesired(.init(modelName: f.id, desiredBuild: f.id,
                revision: "newer", aggregateSHA256: String(repeating: "e", count: 64)))
        } else {
            await f.loop.beginServingDrain(owner: .modelSwitch)
        }
        f.staged.lease.release()
        if change == "cancel" {
            await #expect(throws: CancellationError.self) { try await attempt.value }
        } else {
            #expect(try await attempt.value == nil)
        }
        #expect(await f.loop.revisionUpdatesInProgress.isEmpty)
        #expect(await f.loop.state.refusingNewWork == (change == "model-switch"))
        #expect(await f.loop.revisionTestHash(f.id) == f.oldHash)
        #expect(ModelScanner.resolveLocalPath(modelID: f.id) == f.oldDirectory)
        let retry = try ModelArtifactWriteLease.acquireIfAvailable(modelID: f.id)
        retry.release()
    }
}
