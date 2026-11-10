import CryptoKit
import Darwin
import Foundation
// The model-free script check compiles this file against its own module name.
#if canImport(DarkbloomClusterRuntimeChecks)
@testable import DarkbloomClusterRuntimeChecks
#else
@testable import DarkbloomClusterRuntime
#endif

/// A selected loader's uncached payload reads start from none of the weight files' pages in the file cache:
/// `bypassTensorPayloadCache` drops what a copy, a download or an earlier read left there, through the pinned
/// descriptors, and leaves every other file's pages alone. Real files, residency by `mincore`; no model, no MLX.
enum CheckpointPayloadCacheCheck {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-payload-cache-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let config = Data(#"{"arch":"payload-cache-fixture"}"#.utf8)
        let weightsPath = "model-00001-of-00001.safetensors"
        let weights = seeded(32 << 20)
        let files = [("config.json", config), (weightsPath, weights)]
        var aggregate = SHA256()
        var entries: [[String: Any]] = []
        for (path, data) in files.sorted(by: { $0.0 < $1.0 }) {
            try data.write(to: root.appendingPathComponent(path), options: .withoutOverwriting)
            let digest = Data(SHA256.hash(data: data))
            aggregate.update(data: digest)
            entries.append(["path": path, "sha256": digest.map { String(format: "%02x", $0) }.joined(), "size_bytes": data.count])
        }
        let manifest: [String: Any] = ["aggregate_sha256": aggregate.finalize().map { String(format: "%02x", $0) }.joined(),
            "file_count": files.count, "total_size_bytes": files.reduce(0) { $0 + $1.1.count }, "files": entries]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("manifest.json"), options: .withoutOverwriting)

        let checkpoint = try VerifiedCheckpoint(directory: root, configurationData: config)
        // In the cache as a copy or an earlier read leaves it (verification itself hashes uncached).
        for (path, _) in files { try readThroughCache(root.appendingPathComponent(path)) }
        let cachedWeights = try residentShare(root.appendingPathComponent(weightsPath))
        guard cachedWeights > 0.9, try residentShare(root.appendingPathComponent("config.json")) == 1 else {
            throw Failure(description: "this host did not keep files just read in its cache (weights \(cachedWeights))")
        }

        try checkpoint.bypassTensorPayloadCache()
        let afterWeights = try residentShare(root.appendingPathComponent(weightsPath))
        guard afterWeights < 0.1 else {
            throw Failure(description: "\(Int(afterWeights * 100)) % of the weight file's pages stayed in the cache for its uncached read")
        }
        guard try residentShare(root.appendingPathComponent("config.json")) == 1 else {
            throw Failure(description: "a file that is not a weight file lost its cached pages")
        }
        try checkpoint.checkUnchanged()
        guard let file = checkpoint.files[weightsPath] else { throw Failure(description: "the weight file is not pinned") }
        let read = UnsafeMutableRawBufferPointer.allocate(byteCount: weights.count, alignment: 16_384)
        defer { read.deallocate() }
        guard try file.read(into: read, offset: 0) != nil else {
            throw Failure(description: "the payload read did not take the uncached aligned path")
        }
        guard Data(read) == weights else { throw Failure(description: "the payload read returned other bytes") }
        guard try Data(contentsOf: root.appendingPathComponent(weightsPath)) == weights else {
            throw Failure(description: "the weight file changed")
        }
    }

    /// `count` bytes of a seeded sequence.
    private static func seeded(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            for offset in stride(from: 0, to: raw.count - 7, by: 8) {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                raw.storeBytes(of: state, toByteOffset: offset, as: UInt64.self)
            }
        }
        return data
    }

    private static func readThroughCache(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure(description: "cannot open \(url.lastPathComponent)") }
        defer { close(fd) }
        let chunk = 8 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16_384)
        defer { buffer.deallocate() }
        var offset: off_t = 0
        while true {
            let count = pread(fd, buffer, chunk, offset)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure(description: "cannot read \(url.lastPathComponent)") }
            if count == 0 { return }
            offset += off_t(count)
        }
    }

    /// The share of the file's pages in the file cache, through a shared mapping (`mincore`).
    private static func residentShare(_ url: URL) throws -> Double {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure(description: "cannot open \(url.lastPathComponent)") }
        defer { close(fd) }
        var information = stat()
        guard fstat(fd, &information) == 0, information.st_size > 0 else { throw Failure(description: "cannot size \(url.lastPathComponent)") }
        let length = Int(information.st_size)
        guard let mapping = mmap(nil, length, PROT_READ, MAP_SHARED, fd, 0), mapping != MAP_FAILED else {
            throw Failure(description: "cannot map \(url.lastPathComponent)")
        }
        defer { munmap(mapping, length) }
        let page = Int(getpagesize())
        var vector = [CChar](repeating: 0, count: (length + page - 1) / page)
        guard mincore(mapping, length, &vector) == 0 else { throw Failure(description: "mincore failed") }
        return Double(vector.reduce(0) { $0 + Int($1 & 1) }) / Double(vector.count)
    }
}
