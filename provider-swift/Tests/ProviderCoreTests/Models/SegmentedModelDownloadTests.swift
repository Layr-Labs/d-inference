import Crypto
import Foundation
import Testing
@testable import ProviderCore
import ProviderCoreFoundation

/// A model CDN that serves byte ranges of its bodies (by host, else by file
/// name), with per-test replies for misbehaving ranges.
private final class RangedCDNProtocol: URLProtocol, @unchecked Sendable {
    enum End { case finish, drop, hang }
    struct Reply {
        var status: Int
        var headers: [String: String]
        var body: Data
        var end: End = .finish
    }
    /// `(request, first requested byte or nil, the host's body)`; nil keeps the standard reply.
    typealias Override = @Sendable (URLRequest, Int?, Data) -> Reply?

    nonisolated(unsafe) private static var bodies: [String: Data] = [:]
    nonisolated(unsafe) private static var override: Override?
    nonisolated(unsafe) private static var requests: [(key: String, range: String?)] = []
    private static let lock = NSLock()

    static func reset(bodies: [String: Data], override: Override? = nil) {
        lock.withLock { self.bodies = bodies; self.override = override; requests = [] }
    }

    /// The `Range` header of each request for `key` (a host, or a file name), in order.
    static func ranges(host key: String = "r2.test") -> [String?] {
        lock.withLock { requests }.filter { $0.key == key }.map(\.range)
    }

    static func bounds(_ header: String?) -> (first: Int, last: Int?)? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let first = Int(parts[0]) else { return nil }
        return (first, parts[1].isEmpty ? nil : Int(parts[1]))
    }

    static func standardReply(range header: String?, body: Data) -> Reply {
        guard let (first, last) = bounds(header) else {
            return Reply(status: 200, headers: ["Content-Length": "\(body.count)"], body: body)
        }
        guard first < body.count else {
            return Reply(status: 416, headers: ["Content-Range": "bytes */\(body.count)"], body: Data())
        }
        let end = min(last ?? body.count - 1, body.count - 1)
        let slice = Data(body[first...end])
        return Reply(status: 206, headers: ["Content-Range": "bytes \(first)-\(end)/\(body.count)",
                                            "Content-Length": "\(slice.count)"], body: slice)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let header = request.value(forHTTPHeaderField: "Range")
        let (body, override) = Self.lock.withLock { () -> (Data?, Override?) in
            let key = Self.bodies[url.host!] == nil ? url.lastPathComponent : url.host!
            Self.requests.append((key, header))
            return (Self.bodies[key], Self.override)
        }
        guard let body else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let reply = override?(request, Self.bounds(header)?.first, body)
            ?? Self.standardReply(range: header, body: body)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < reply.body.count {
            let end = min(offset + 16 * 1024, reply.body.count)
            client?.urlProtocol(self, didLoad: reply.body.subdata(in: offset..<end))
            offset = end
        }
        switch reply.end {
        case .finish: client?.urlProtocolDidFinishLoading(self)
        case .drop:
            // On a later tick, as a real drop: failing in the same tick as the
            // last `didLoad` makes the loading system discard the delivered bytes.
            let client = self.client
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        case .hang: break
        }
    }

    override func stopLoading() {}
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int: Int] = [:]
    /// How many times `key` was seen before this call.
    func next(_ key: Int) -> Int { lock.withLock { defer { counts[key, default: 0] += 1 }; return counts[key, default: 0] } }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func record(_ value: Int64) { lock.withLock { values.append(value) } }
    var all: [Int64] { lock.withLock { values } }
}

@Suite("Ranged model-file downloads", .serialized)
struct SegmentedModelDownloadTests {
    private static let size = 1 << 20
    private static let rangeBytes = size / 4
    private let bytes = Data((0..<SegmentedModelDownloadTests.size).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 13) })

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func downloader(segments: Int = 4) -> ModelDownloader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RangedCDNProtocol.self]
        var downloader = ModelDownloader(r2CDNURL: "https://r2.test", urlSession: URLSession(configuration: config),
                                         retryBackoff: .milliseconds(1))
        downloader.segmentsPerFile = segments
        downloader.segmentMinimumFileBytes = 64 * 1024
        return downloader
    }

    private func job(_ directory: URL, content: Data? = nil, name: String = "model.safetensors")
        -> (file: ManifestFile, destination: URL, url: String) {
        let content = content ?? bytes
        return (ManifestFile(path: name, sizeBytes: Int64(content.count), sha256: digest(content), role: "weight"),
                directory.appendingPathComponent(name), "https://r2.test/v2/test/\(name)")
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func range(_ index: Int, from first: Int? = nil) -> String {
        "bytes=\(first ?? index * Self.rangeBytes)-\((index + 1) * Self.rangeBytes - 1)"
    }

    private func record(_ destination: URL) -> URL {
        SegmentedPartFile.recordURL(for: destination.appendingPathExtension("part"))
    }

    private func savedLayout(_ destination: URL) -> SegmentedPartLayout? {
        guard case .valid(let layout) = SegmentedPartFile.saved(
            partial: destination.appendingPathExtension("part"), size: Int64(Self.size)) else { return nil }
        return layout
    }

    // MARK: - Transfer

    @Test("a large file arrives over four exact byte ranges after one ranged probe, verified and promoted")
    func rangedDownload() async throws {
        RangedCDNProtocol.reset(bodies: ["r2.test": bytes])
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let job = job(dir)
        let progress = ProgressLog()
        try await downloader().downloadManifestFileWithResume(job, onChunk: { progress.record($0) })

        #expect(try Data(contentsOf: job.destination) == bytes)
        let requested = RangedCDNProtocol.ranges()
        #expect(requested.first == "bytes=0-0")
        #expect(Set(requested.dropFirst().compactMap { $0 }) == Set((0..<4).map { range($0) }))
        #expect(requested.count == 5)
        #expect(!FileManager.default.fileExists(atPath: job.destination.appendingPathExtension("part").path))
        #expect(!FileManager.default.fileExists(atPath: record(job.destination).path))
        let values = progress.all
        #expect(values == values.sorted())
        #expect(values.last == Int64(Self.size))
    }

    @Test("DARKBLOOM_DOWNLOAD_SEGMENTS=1 and small files keep the single GET without a probe", arguments: [false, true])
    func singleStream(smallFile: Bool) async throws {
        RangedCDNProtocol.reset(bodies: ["r2.test": bytes])
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var downloader = downloader(segments: smallFile ? 4 : 1)
        if smallFile { downloader.segmentMinimumFileBytes = Int64(Self.size) + 1 }
        let job = job(dir)
        try await downloader.downloadManifestFileWithResume(job)
        #expect(try Data(contentsOf: job.destination) == bytes)
        #expect(RangedCDNProtocol.ranges() == [nil])
    }

    @Test("a source that ignores ranges or reports another size gets the single-stream GET",
          arguments: ["ignores", "other total"])
    func probeRefused(reason: String) async throws {
        let size = Self.size
        RangedCDNProtocol.reset(bodies: ["r2.test": bytes]) { request, first, body in
            guard first == 0, request.value(forHTTPHeaderField: "Range") == "bytes=0-0" else { return nil }
            if reason == "ignores" {
                return .init(status: 200, headers: ["Content-Length": "\(body.count)"], body: body)
            }
            return .init(status: 206, headers: ["Content-Range": "bytes 0-0/\(size + 1)"], body: body.prefix(1))
        }
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let job = job(dir)
        try await downloader().downloadManifestFileWithResume(job)
        #expect(try Data(contentsOf: job.destination) == bytes)
        #expect(RangedCDNProtocol.ranges() == ["bytes=0-0", nil])
        #expect(!FileManager.default.fileExists(atPath: record(job.destination).path))
    }

    @Test("a range answered for another offset writes nothing and is asked again")
    func misplacedRangeRetried() async throws {
        let seen = Counter()
        let rangeBytes = Self.rangeBytes
        RangedCDNProtocol.reset(bodies: ["r2.test": bytes]) { _, first, body in
            guard first == 2 * rangeBytes, seen.next(2) == 0 else { return nil }
            let lie = first! + 1
            return .init(status: 206, headers: ["Content-Range": "bytes \(lie)-\(3 * rangeBytes - 1)/\(body.count)"],
                         body: Data(body[lie..<(3 * rangeBytes)]))
        }
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let job = job(dir)
        try await downloader().downloadManifestFileWithResume(job)
        #expect(try Data(contentsOf: job.destination) == bytes)
        #expect(RangedCDNProtocol.ranges().filter { $0 == range(2) }.count == 2)
    }

    @Test("bytes that fail the file's SHA-256 delete the .part and its record, and the file fails")
    func corruptRangeFails() async throws {
        let rangeBytes = Self.rangeBytes
        RangedCDNProtocol.reset(bodies: ["r2.test": bytes]) { request, first, body in
            guard first == rangeBytes else { return nil }
            var reply = RangedCDNProtocol.standardReply(range: request.value(forHTTPHeaderField: "Range"), body: body)
            reply.body[reply.body.startIndex] ^= 0xFF
            return reply
        }
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let job = job(dir)
        let error = await #expect(throws: ModelCatalogError.self) {
            try await downloader().downloadManifestFileWithResume(job)
        }
        #expect(String(describing: error).contains("SHA-256 mismatch"))
        #expect(!FileManager.default.fileExists(atPath: job.destination.path))
        #expect(!FileManager.default.fileExists(atPath: job.destination.appendingPathExtension("part").path))
        #expect(!FileManager.default.fileExists(atPath: record(job.destination).path))
    }

    // MARK: - Resume

    @Test("a cancel keeps exactly the written bytes in the record; the next run fetches only the rest")
    func cancelThenResume() async throws {
        let rangeBytes = Self.rangeBytes
        let partialBytes = 80 * 1024
        RangedCDNProtocol.reset(bodies: ["r2.test": bytes]) { request, first, body in
            guard first == 2 * rangeBytes else { return nil }
            var reply = RangedCDNProtocol.standardReply(range: request.value(forHTTPHeaderField: "Range"), body: body)
            reply.body = reply.body.prefix(partialBytes)
            reply.end = .hang
            return reply
        }
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let job = job(dir)
        let progress = ProgressLog()
        let worker = downloader()
        let transfer = Task { try await worker.downloadManifestFileWithResume(job, onChunk: { progress.record($0) }) }
        let expected = Int64(3 * rangeBytes + partialBytes)
        let deadline = Date().addingTimeInterval(10)
        while progress.all.last != expected, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(progress.all.last == expected)
        transfer.cancel()
        await #expect(throws: CancellationError.self) { try await transfer.value }

        let layout = try #require(savedLayout(job.destination))
        #expect(layout.ranges.map(\.done) == [rangeBytes, rangeBytes, partialBytes, rangeBytes].map(Int64.init))
        #expect(SegmentedPartFile.accountedBytes(partial: job.destination.appendingPathExtension("part"),
                                                 size: Int64(Self.size)) == expected)

        RangedCDNProtocol.reset(bodies: ["r2.test": bytes])
        try await downloader().downloadManifestFileWithResume(job)
        #expect(try Data(contentsOf: job.destination) == bytes)
        #expect(RangedCDNProtocol.ranges() == ["bytes=0-0", range(2, from: 2 * rangeBytes + partialBytes)])
        #expect(!FileManager.default.fileExists(atPath: record(job.destination).path))
    }

    @Test("a range that stops getting bytes fails the file after its attempts and keeps what it wrote")
    func exhaustedRangeKeepsBytes() async throws {
        let rangeBytes = Self.rangeBytes
        let seen = Counter()
        RangedCDNProtocol.reset(bodies: ["r2.test": bytes]) { request, first, body in
            guard let first, (3 * rangeBytes)..<(4 * rangeBytes) ~= first else { return nil }
            guard seen.next(3) == 0 else { return .init(status: 503, headers: [:], body: Data()) }
            var reply = RangedCDNProtocol.standardReply(range: request.value(forHTTPHeaderField: "Range"), body: body)
            reply.body = reply.body.prefix(48 * 1024)
            reply.end = .drop
            return reply
        }
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let job = job(dir)
        await #expect(throws: ModelCatalogError.self) { try await downloader().downloadManifestFileWithResume(job) }
        // One attempt that wrote bytes, then three in a row that wrote none.
        #expect(RangedCDNProtocol.ranges().filter { $0?.hasPrefix("bytes=\(3 * rangeBytes + 48 * 1024)-") == true }.count == 3)
        #expect(savedLayout(job.destination)?.ranges[3].done == Int64(48 * 1024))
    }

    @Test("a single-stream .part prefix is credited to the ranges it covers")
    func singleStreamPrefixCredited() async throws {
        RangedCDNProtocol.reset(bodies: ["r2.test": bytes])
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let job = job(dir)
        let prefix = Self.rangeBytes + 44 * 1024
        try bytes.prefix(prefix).write(to: job.destination.appendingPathExtension("part"))
        try await downloader().downloadManifestFileWithResume(job)
        #expect(try Data(contentsOf: job.destination) == bytes)
        #expect(Set(RangedCDNProtocol.ranges().dropFirst().compactMap { $0 })
                == [range(1, from: prefix), range(2), range(3)])
    }

    @Test("with one connection a ranged .part keeps only its gap-free prefix and resumes from it")
    func switchOffCollapsesToPrefix() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let job = job(dir)
        let partial = job.destination.appendingPathExtension("part")
        var layout = SegmentedPartLayout.planned(size: Int64(Self.size), count: 4, prefix: 0)
        let done = [Self.rangeBytes, 10_000, Self.rangeBytes, 0]
        _ = try SegmentedPartFile.prepare(partial: partial, size: Int64(Self.size), count: 4)
        let handle = try FileHandle(forWritingTo: partial)
        for (index, count) in done.enumerated() {
            try handle.seek(toOffset: UInt64(index * Self.rangeBytes))
            try handle.write(contentsOf: bytes[(index * Self.rangeBytes)..<(index * Self.rangeBytes + count)])
            layout.ranges[index].done = Int64(count)
        }
        try handle.close()
        try SegmentedPartFile.save(layout, partial: partial)

        RangedCDNProtocol.reset(bodies: ["r2.test": bytes])
        try await downloader(segments: 1).downloadManifestFileWithResume(job)
        #expect(try Data(contentsOf: job.destination) == bytes)
        #expect(RangedCDNProtocol.ranges() == ["bytes=\(Self.rangeBytes + 10_000)-"])
        #expect(!FileManager.default.fileExists(atPath: record(job.destination).path))
    }

    @Test("an unreadable record discards the .part: no byte it cannot account for is kept")
    func unusableRecordDiscarded() async throws {
        RangedCDNProtocol.reset(bodies: ["r2.test": bytes])
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let job = job(dir)
        let partial = job.destination.appendingPathExtension("part")
        try Data(repeating: 7, count: Self.size).write(to: partial)
        try Data("{not a record".utf8).write(to: SegmentedPartFile.recordURL(for: partial))
        #expect(SegmentedPartFile.saved(partial: partial, size: Int64(Self.size)) == .unusable)
        #expect(SegmentedPartFile.accountedBytes(partial: partial, size: Int64(Self.size)) == 0)
        try await downloader().downloadManifestFileWithResume(job)
        #expect(try Data(contentsOf: job.destination) == bytes)
        #expect(Set(RangedCDNProtocol.ranges().dropFirst().compactMap { $0 }) == Set((0..<4).map { range($0) }))
    }

    @Test("a record counting bytes beyond the .part is unusable")
    func recordBeyondPartIsUnusable() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let partial = dir.appendingPathComponent("model.safetensors.part")
        try bytes.prefix(1000).write(to: partial)
        var layout = SegmentedPartLayout.planned(size: Int64(Self.size), count: 4, prefix: 1000)
        try SegmentedPartFile.save(layout, partial: partial)
        #expect(SegmentedPartFile.saved(partial: partial, size: Int64(Self.size)) == .valid(layout))
        layout.ranges[1].done = 1
        try SegmentedPartFile.save(layout, partial: partial)
        #expect(SegmentedPartFile.saved(partial: partial, size: Int64(Self.size)) == .unusable)
        #expect(SegmentedPartFile.saved(partial: partial, size: Int64(Self.size) + 1) == .unusable)
    }

    // MARK: - Sources

    @Test("Hugging Face ranges retry a dropped transfer from where it stopped, without falling back to R2")
    func huggingFaceRangeResumesAfterDrop() async throws {
        let rangeBytes = Self.rangeBytes
        let seen = Counter()
        RangedCDNProtocol.reset(bodies: ["huggingface.co": bytes, "r2.test": bytes]) { request, first, body in
            guard request.url?.host == "huggingface.co", let first,
                  (2 * rangeBytes)..<(3 * rangeBytes) ~= first, seen.next(2) < 2 else { return nil }
            var reply = RangedCDNProtocol.standardReply(range: request.value(forHTTPHeaderField: "Range"), body: body)
            reply.body = reply.body.prefix(32 * 1024)
            reply.end = .drop
            return reply
        }
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let job = job(dir)
        let artifact = HuggingFaceArtifact(repoID: "EigenLabs/test", revision: String(repeating: "a", count: 40))
        try await downloader().downloadManifestFileWithResume(job, huggingFaceArtifact: artifact)
        #expect(try Data(contentsOf: job.destination) == bytes)
        #expect(RangedCDNProtocol.ranges(host: "r2.test").isEmpty)
        #expect(RangedCDNProtocol.ranges(host: "huggingface.co").contains(range(2, from: 2 * rangeBytes + 64 * 1024)))
    }

    @Test("a failing Hugging Face range falls back to R2 with neither its .part nor its record")
    func huggingFaceFallbackStartsClean() async throws {
        let rangeBytes = Self.rangeBytes
        RangedCDNProtocol.reset(bodies: ["huggingface.co": bytes, "r2.test": bytes]) { request, first, _ in
            guard request.url?.host == "huggingface.co", first == 3 * rangeBytes else { return nil }
            return .init(status: 503, headers: [:], body: Data())
        }
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let job = job(dir)
        let artifact = HuggingFaceArtifact(repoID: "EigenLabs/test", revision: String(repeating: "a", count: 40))
        try await downloader().downloadManifestFileWithResume(job, huggingFaceArtifact: artifact)
        #expect(try Data(contentsOf: job.destination) == bytes)
        let r2 = RangedCDNProtocol.ranges(host: "r2.test")
        #expect(r2.first == "bytes=0-0")
        #expect(Set(r2.dropFirst().compactMap { $0 }) == Set((0..<4).map { range($0) }))
    }

    @Test("uncached writes: the .part's descriptor takes F_NOCACHE, and the ranged file verifies uncached",
          arguments: [false, true])
    func uncachedWrites(uncached: Bool) async throws {
        RangedCDNProtocol.reset(bodies: ["r2.test": bytes])
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let partial = dir.appendingPathComponent("probe.part")
        let layout = try SegmentedPartFile.prepare(partial: partial, size: 4096, count: 2)
        let writer = try SegmentedPartWriter(partial: partial, layout: layout, uncached: uncached, onChunk: nil)
        #expect(writer.cachingDisabled == uncached)
        try writer.close()

        var downloader = downloader()
        downloader.uncachedWrites = uncached
        let job = job(dir)
        try await downloader.downloadManifestFileWithResume(job)
        #expect(try Data(contentsOf: job.destination) == bytes)
        #expect(RangedCDNProtocol.ranges().count == 5)
    }

    // MARK: - Accounting and limits

    @Test("free-disk planning credits a ranged .part's counted bytes, not its pre-sized length")
    func planningCreditsCountedBytes() async throws {
        let id = "test-org/ranged-\(UUID().uuidString)"
        let prefix = "v2/ranged/\(UUID().uuidString)"
        let file = ManifestFile(path: "model.safetensors", sizeBytes: Int64(Self.size), sha256: digest(bytes), role: "weight")
        let aggregate = digest(Data(SHA256.hash(data: bytes)))
        let manifest = ModelManifest(schemaVersion: 1, modelID: id, version: "v1", r2Prefix: prefix,
            aggregateSHA256: aggregate, totalSizeBytes: Int64(Self.size), fileCount: 1, files: [file], createdAt: Date())
        let model = CatalogModel(id: id, s3Name: prefix, displayName: id, sizeGb: 0, version: "v1",
                                 r2Prefix: prefix, aggregateSHA256: aggregate)
        defer { try? FileManager.default.removeItem(at: ModelDownloader.cacheModelDirectory(for: id)) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestBody = try encoder.encode(manifest)
        RangedCDNProtocol.reset(bodies: ["r2.test": manifestBody])

        let staging = ModelDownloader.cacheSnapshotDirectory(for: id).deletingLastPathComponent()
            .appendingPathComponent(ModelDownloader.localStagingDirName(r2Prefix: prefix))
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let partial = staging.appendingPathComponent("model.safetensors.part")
        var layout = try SegmentedPartFile.prepare(partial: partial, size: Int64(Self.size), count: 4)
        layout.ranges[0].done = 1000
        try SegmentedPartFile.save(layout, partial: partial)

        let attributes = try FileManager.default.attributesOfItem(atPath: partial.path)
        #expect(attributes[.size] as? Int64 == Int64(Self.size))
        let plan = try await downloader().selectedDownloadPlan(models: [model])
        #expect(plan.remainingBytes == Int64(Self.size) - 1000)
    }

    @Test("one download opens at most 16 connections over the files it fetches at once")
    func connectionCeiling() async throws {
        #expect(ModelDownloadSegments.perFile(requested: 4, filesAtOnce: 4) == 4)
        #expect(ModelDownloadSegments.perFile(requested: 8, filesAtOnce: 4) == 4)
        #expect(ModelDownloadSegments.perFile(requested: 8, filesAtOnce: 3) == 5)
        #expect(ModelDownloadSegments.perFile(requested: 8, filesAtOnce: 2) == 8)
        #expect(ModelDownloadSegments.perFile(requested: 8, filesAtOnce: 1) == 8)
        #expect(ModelDownloadSegments.perFile(requested: 1, filesAtOnce: 4) == 1)

        let id = "test-org/ranged-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: ModelDownloader.cacheModelDirectory(for: id)) }
        let parts = (0..<4).map { index in Data(bytes[(index * Self.rangeBytes)..<((index + 1) * Self.rangeBytes)]) }
        var bodies: [String: Data] = [:]
        var files: [ManifestFile] = []
        var digests = Data()
        for (index, part) in parts.enumerated() {
            bodies["model-\(index).safetensors"] = part
            files.append(ManifestFile(path: "model-\(index).safetensors", sizeBytes: Int64(part.count),
                                      sha256: digest(part), role: "weight"))
            digests.append(Data(SHA256.hash(data: part)))
        }
        RangedCDNProtocol.reset(bodies: bodies)
        let aggregate = digest(digests)
        let manifest = ModelManifest(schemaVersion: 1, modelID: id, version: "v1", r2Prefix: "v2/ceiling/v1",
            aggregateSHA256: aggregate, totalSizeBytes: Int64(Self.size), fileCount: 4, files: files, createdAt: Date())
        let model = CatalogModel(id: id, s3Name: "v2/ceiling/v1", displayName: id, sizeGb: 0,
                                 r2Prefix: "v2/ceiling/v1", aggregateSHA256: aggregate)
        var downloader = downloader(segments: 8)
        downloader.byteProgress = { _, _ in }
        try await downloader.downloadManifestModel(model: model, manifest: manifest, onProgress: nil)
        for index in 0..<4 {
            let requested = RangedCDNProtocol.ranges(host: "model-\(index).safetensors")
            #expect(requested.first == "bytes=0-0")
            #expect(requested.count == 1 + 4)
        }
    }

    // MARK: - Switch

    @Test("DARKBLOOM_DOWNLOAD_SEGMENTS parses to 1…8 ranges, 4 by default")
    func switchValues() {
        let key = ModelDownloadSegments.environmentKey
        #expect(key == "DARKBLOOM_DOWNLOAD_SEGMENTS")
        let cases: [(String?, Int)] = [
            (nil, 4), ("", 4), ("4", 4), (" 8 ", 8), ("2", 2), ("1", 1), ("0", 1), ("off", 1), ("FALSE", 1),
            ("no", 1), ("9", 8), ("64", 8), ("-2", 4), ("four", 4), ("2.5", 4),
        ]
        for (value, expected) in cases {
            #expect(ModelDownloadSegments.count(environment: value.map { [key: $0] } ?? [:]) == expected,
                    "\(value ?? "unset")")
        }
        #expect(LaunchAgent.passthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "1"])[key] == "1")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }
}
