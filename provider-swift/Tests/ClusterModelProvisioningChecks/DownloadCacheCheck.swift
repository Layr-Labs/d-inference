import Foundation
import Darwin

/// The catalog download in `darkbloom cluster`'s provisioning writes with the file cache off, like the copy over the
/// cable, while single-Mac downloads keep their behaviour: the product's own `StreamingFileDownloadDelegate` (built
/// with plain swiftc by run.sh) is fed a 200 response and 64 MiB of body, and the page cache residency of the written
/// file is read back with mincore(2). Model-free, no network: the delegate's callbacks are called directly.
enum ModelCatalogError: Error { case downloadFailed(String) }   // stands in for the product's (ModelCatalog.swift)

@main enum DownloadCacheCheck {
    static func resident(_ path: String) -> Double {
        let fd = open(path, O_RDONLY | O_CLOEXEC); defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_size > 0 else { return -1 }
        let length = Int(info.st_size)
        guard let mapped = mmap(nil, length, PROT_READ, MAP_SHARED, fd, 0), mapped != MAP_FAILED else { return -1 }
        defer { munmap(mapped, length) }
        let page = Int(getpagesize()), pages = (length + page - 1) / page
        var vector = [CChar](repeating: 0, count: pages)
        guard mincore(mapped, length, &vector) == 0 else { return -1 }
        return Double(vector.filter { $0 & 1 != 0 }.count) / Double(pages)
    }

    /// Streams 64 MiB through the delegate into `partial` and returns the fraction of its pages left in the cache.
    static func download(uncached: Bool?, into partial: URL) -> Double {
        let delegate = uncached.map { StreamingFileDownloadDelegate(partial: partial, existingBytes: 0, label: "shard", uncached: $0, onChunk: nil) }
            ?? StreamingFileDownloadDelegate(partial: partial, existingBytes: 0, label: "shard", onChunk: nil)
        let session = URLSession(configuration: .ephemeral)
        let url = URL(string: "http://127.0.0.1:9/shard")!
        let task = session.dataTask(with: url)   // never resumed: the callbacks are driven here
        delegate.urlSession(session, dataTask: task, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!) { _ in }
        let chunk = Data((0..<(1 << 20) + 777).map { UInt8(truncatingIfNeeded: $0) })
        for _ in 0..<64 { delegate.urlSession(session, dataTask: task, didReceive: chunk) }
        delegate.urlSession(session, task: task, didCompleteWithError: nil)
        session.invalidateAndCancel()
        return resident(partial.path)
    }

    static func main() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("download-cache-\(getpid())")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var failures = [String](), passed = 0
        func expect(_ condition: Bool, _ message: String) { if condition { passed += 1 } else { failures.append(message) } }
        let defaultCached = download(uncached: nil, into: directory.appendingPathComponent("a.part"))
        let cached = download(uncached: false, into: directory.appendingPathComponent("b.part"))
        let uncached = download(uncached: true, into: directory.appendingPathComponent("c.part"))
        expect((try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("c.part").path)[.size] as? Int) == 64 * ((1 << 20) + 777),
            "the uncached download wrote every byte")
        expect(defaultCached > 0.5, "single-Mac downloads (default) keep writing through the file cache: \(defaultCached) resident")
        expect(cached > 0.5, "uncached off: written through the file cache: \(cached) resident")
        expect(uncached < 0.1, "uncached on (the cluster's provisioning): the written bytes are not kept in the file cache: \(uncached) resident")
        print("download cache check: \(passed) passed, \(failures.count) failed (resident fractions: default \(defaultCached), off \(cached), on \(uncached))")
        for failure in failures { print("FAIL " + failure) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
