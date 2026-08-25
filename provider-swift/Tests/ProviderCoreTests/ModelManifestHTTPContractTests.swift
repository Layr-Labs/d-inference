import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdCore
import Logging
import NIOCore
import Testing
@testable import ProviderCore

@Suite("Model manifest HTTP contract", .serialized)
struct ModelManifestHTTPContractTests {
    @Test("coordinator manifest accepts exact byte boundary and rejects one byte over")
    func coordinatorManifestByteBoundary() async throws {
        let server = ManifestContractHTTPServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }

        let manifest = makeHTTPContractManifest()
        let path = "/v1/models/catalog/manifest/\(manifest.modelID)"
        let encoded = try encodeHTTPContractManifest(manifest)
        #expect(encoded.count < ModelManifestContract.maximumEncodedBytes)

        server.setBody(
            paddedManifest(
                encoded,
                byteCount: ModelManifestContract.maximumEncodedBytes),
            for: path)
        let client = ModelCatalogClient(coordinatorURL: baseURL.absoluteString)
        let decoded = try await client.fetchManifest(modelID: manifest.modelID)
        #expect(decoded == manifest)

        server.setBody(
            paddedManifest(
                encoded,
                byteCount: ModelManifestContract.maximumEncodedBytes + 1),
            for: path)
        do {
            _ = try await client.fetchManifest(modelID: manifest.modelID)
            Issue.record("one-byte-over manifest response was accepted")
        } catch {
            #expect(error.localizedDescription.contains("exceeds"))
        }
    }

    @Test("coordinator manifest rejects file count, negative size, and aggregate overflow")
    func coordinatorManifestStructure() async throws {
        let server = ManifestContractHTTPServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }

        let modelID = "contract-model"
        let path = "/v1/models/catalog/manifest/\(modelID)"
        let client = ModelCatalogClient(coordinatorURL: baseURL.absoluteString)

        let excessiveCount = makeHTTPContractManifest(
            modelID: modelID,
            fileCount: ModelManifestContract.maximumFileCount + 1)
        server.setBody(try encodeHTTPContractManifest(excessiveCount), for: path)
        await expectManifestFailure(client: client, modelID: modelID, containing: "file_count")

        let negativeSize = makeHTTPContractManifest(
            modelID: modelID,
            totalSizeBytes: 0,
            files: [
                ManifestFile(
                    path: "config.json",
                    sizeBytes: -1,
                    sha256: String(repeating: "b", count: 64),
                    role: "config")
            ])
        server.setBody(try encodeHTTPContractManifest(negativeSize), for: path)
        await expectManifestFailure(client: client, modelID: modelID, containing: "nonnegative")

        let overflowing = makeHTTPContractManifest(
            modelID: modelID,
            totalSizeBytes: Int64.max,
            fileCount: 2,
            files: [
                ManifestFile(
                    path: "a.bin",
                    sizeBytes: Int64.max,
                    sha256: String(repeating: "b", count: 64),
                    role: "weight"),
                ManifestFile(
                    path: "b.bin",
                    sizeBytes: 1,
                    sha256: String(repeating: "c", count: 64),
                    role: "weight"),
            ])
        server.setBody(try encodeHTTPContractManifest(overflowing), for: path)
        await expectManifestFailure(client: client, modelID: modelID, containing: "overflow")
    }

    @Test("direct CDN manifest cannot bypass byte or structure validation")
    func directCDNManifestUsesSharedContract() async throws {
        let server = ManifestContractHTTPServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }

        let modelID = "cdn-contract-model"
        let prefix = "v2/cdn-contract-model/v1"
        let path = "/\(prefix)/manifest.json"
        let model = CatalogModel(
            id: modelID,
            s3Name: "unused",
            displayName: "CDN Contract",
            sizeGb: 0.001,
            r2Prefix: prefix)
        let downloader = ModelDownloader(r2CDNURL: baseURL.absoluteString)

        let negative = makeHTTPContractManifest(
            modelID: modelID,
            r2Prefix: prefix,
            totalSizeBytes: 0,
            files: [
                ManifestFile(
                    path: "config.json",
                    sizeBytes: -1,
                    sha256: String(repeating: "b", count: 64),
                    role: "config")
            ])
        server.setBody(try encodeHTTPContractManifest(negative), for: path)
        do {
            _ = try await downloader.fetchManifestFromCDN(model: model)
            Issue.record("direct CDN accepted a negative manifest file size")
        } catch {
            #expect(error.localizedDescription.contains("nonnegative"))
        }

        let valid = makeHTTPContractManifest(modelID: modelID, r2Prefix: prefix)
        let encoded = try encodeHTTPContractManifest(valid)
        server.setBody(
            paddedManifest(
                encoded,
                byteCount: ModelManifestContract.maximumEncodedBytes + 1),
            for: path)
        do {
            _ = try await downloader.fetchManifestFromCDN(model: model)
            Issue.record("direct CDN accepted an oversized manifest response")
        } catch {
            #expect(error.localizedDescription.contains("exceeds"))
        }
    }
}

private func makeHTTPContractManifest(
    modelID: String = "boundary-model",
    r2Prefix: String = "v2/boundary-model/v1",
    totalSizeBytes: Int64 = 5,
    fileCount: Int = 1,
    files: [ManifestFile] = [
        ManifestFile(
            path: "config.json",
            sizeBytes: 5,
            sha256: String(repeating: "b", count: 64),
            role: "config")
    ]
) -> ModelManifest {
    ModelManifest(
        schemaVersion: 1,
        modelID: modelID,
        version: "v1",
        r2Prefix: r2Prefix,
        aggregateSHA256: String(repeating: "a", count: 64),
        totalSizeBytes: totalSizeBytes,
        fileCount: fileCount,
        files: files,
        createdAt: Date(timeIntervalSince1970: 0))
}

private func encodeHTTPContractManifest(_ manifest: ModelManifest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(manifest)
}

private func paddedManifest(_ encoded: Data, byteCount: Int) -> Data {
    precondition(encoded.count <= byteCount)
    var result = encoded
    result.append(Data(repeating: UInt8(ascii: " "), count: byteCount - encoded.count))
    return result
}

private func expectManifestFailure(
    client: ModelCatalogClient,
    modelID: String,
    containing expectedText: String
) async {
    do {
        _ = try await client.fetchManifest(modelID: modelID)
        Issue.record("invalid manifest was accepted")
    } catch {
        #expect(error.localizedDescription.contains(expectedText))
    }
}

/// Real loopback HTTP server used to exercise URLSession framing and streaming.
private final class ManifestContractHTTPServer: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String: Data] = [:]
    private var serverTask: Task<Void, Never>?

    func setBody(_ body: Data, for path: String) {
        lock.lock()
        bodies[path] = body
        lock.unlock()
    }

    private func body(for path: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return bodies[path]
    }

    func start() async throws -> URL {
        var logger = Logger(label: "ManifestContractHTTPServer")
        logger.logLevel = .critical
        let router = Router(context: BasicRequestContext.self)
        router.get("**") { [weak self] request, _ -> Response in
            guard let self,
                  let body = self.body(for: request.uri.path)
            else {
                return Response(status: .notFound)
            }
            var headers = HTTPFields()
            headers[.cacheControl] = "no-store"
            return Response(
                status: .ok,
                headers: headers,
                body: .init(byteBuffer: ByteBuffer(bytes: body)))
        }

        let portBox = ManifestContractPortBox()
        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname("127.0.0.1", port: 0),
                serverName: "ManifestContractHTTPServer"),
            onServerRunning: { @Sendable channel in
                portBox.complete(channel.localAddress?.port ?? 0)
            },
            logger: logger)
        let task = Task<Void, Never> {
            try? await app.runService(gracefulShutdownSignals: [])
        }
        let port = await portBox.value
        guard port > 0 else {
            task.cancel()
            throw URLError(.cannotConnectToHost)
        }
        lock.lock()
        serverTask = task
        lock.unlock()
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func shutdown() async {
        lock.lock()
        let task = serverTask
        serverTask = nil
        lock.unlock()
        task?.cancel()
        _ = await task?.value
    }
}

private final class ManifestContractPortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var port: Int?
    private var continuation: CheckedContinuation<Int, Never>?

    var value: Int {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let port {
                    lock.unlock()
                    continuation.resume(returning: port)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }
    }

    func complete(_ port: Int) {
        lock.lock()
        guard self.port == nil else {
            lock.unlock()
            return
        }
        self.port = port
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: port)
    }
}
