import Crypto
import Foundation
import Testing
@testable import ProviderCore
import ProviderCoreFoundation

extension HuggingFaceDownloadTests {
    @Suite("R2 chunk Swift task cancellation", .serialized)
    struct R2ChunkTaskCancellationTests {
        private func hash(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        // Bound both network-start and cancellation-completion waits, including
        // regressions where cancellation stops reaching URLSession entirely.
        private func firstEvent(_ stream: AsyncStream<Bool>) async -> Bool? {
            await withTaskGroup(of: Bool?.self) { group in
                group.addTask {
                    var events = stream.makeAsyncIterator()
                    return await events.next()
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    return nil
                }
                defer { group.cancelAll() }
                return await group.next() ?? nil
            }
        }

        @Test("Task.cancel preserves assembled chunks and retry downloads only the suffix")
        func cancellationRetainsAssembly() async throws {
            let parts = [Data(repeating: 1, count: 64), Data(repeating: 2, count: 8)]
            let complete = parts.reduce(Data(), +)
            let id = "test-chunk-task-cancellation/\(UUID().uuidString)"
            let aggregate = hash(Data(SHA256.hash(data: complete)))
            let file = ManifestFile(path: "weights.safetensors", sizeBytes: 72,
                sha256: hash(complete), role: "weight",
                r2Chunks: parts.map { ManifestChunk(sizeBytes: Int64($0.count), sha256: hash($0)) })
            let model = CatalogModel(id: id, s3Name: "v2/test", displayName: "Test", sizeGb: 0,
                r2Prefix: "v2/test", aggregateSHA256: aggregate)
            let manifest = ModelManifest(schemaVersion: 1, modelID: id, version: "v1", r2Prefix: "v2/test",
                aggregateSHA256: aggregate, totalSizeBytes: file.sizeBytes, fileCount: 1,
                files: [file], createdAt: Date())
            let bodies = Dictionary(uniqueKeysWithValues: parts.enumerated().map {
                (String(format: "/v2/test/weights.safetensors.chunks/%06d.bin", $0.offset), $0.element)
            })
            let modelDirectory = ModelDownloader.cacheModelDirectory(for: id)
            defer { try? FileManager.default.removeItem(at: modelDirectory) }
            let staging = modelDirectory.appendingPathComponent("snapshots")
                .appendingPathComponent(ModelDownloader.localStagingDirName(r2Prefix: "v2/test"))
            let assembled = staging.appendingPathComponent(file.path).appendingPathExtension("r2-transfer")
                .appendingPathComponent("assembled")
            let (started, startedContinuation) = AsyncStream<Bool>.makeStream()
            let (finished, finishedContinuation) = AsyncStream<Bool>.makeStream()
            defer {
                startedContinuation.finish()
                finishedContinuation.finish()
                ModelDownloadURLProtocol.reset(bodies: [:])
            }
            ModelDownloadURLProtocol.reset(bodies: bodies,
                heldRequests: ["/v2/test/weights.safetensors.chunks/000001.bin": startedContinuation])
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ModelDownloadURLProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let downloader = ModelDownloader(r2CDNURL: "https://r2.test", urlSession: session)
            let download = Task {
                do {
                    try await downloader.downloadManifestModel(model: model, manifest: manifest, onProgress: nil)
                    finishedContinuation.yield(false)
                } catch {
                    let cancellation = error is CancellationError || (error as? URLError)?.code == .cancelled
                    finishedContinuation.yield(Task.isCancelled && cancellation)
                }
                finishedContinuation.finish()
            }
            defer { download.cancel() }

            try #require(await firstEvent(started) == true, "second chunk request did not start")
            #expect(try Data(contentsOf: assembled) == parts[0])
            download.cancel()
            try #require(await firstEvent(finished) == true, "download did not finish with task cancellation")
            #expect(try Data(contentsOf: assembled) == parts[0])
            #expect(!FileManager.default.fileExists(atPath: ModelDownloader.cacheSnapshotDirectory(for: id).path))

            ModelDownloadURLProtocol.reset(bodies: bodies)
            try await downloader.downloadManifestModel(model: model, manifest: manifest, onProgress: nil)
            #expect(ModelDownloadURLProtocol.captured().map { $0.url!.lastPathComponent } == ["000001.bin"])
            let published = ModelDownloader.cacheSnapshotDirectory(for: id).appendingPathComponent(file.path)
            #expect(try Data(contentsOf: published) == complete)
        }
    }
}
